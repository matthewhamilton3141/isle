#!/bin/sh
#
# sign-release.sh — cut a signed Isle release for the auto-updater.
#
# Builds the Release app, wraps it in a DMG, signs the DMG with the Ed25519
# private key, and writes dist/latest.json. Upload BOTH the DMG and latest.json
# to the GitHub release for tag v<version> and the updater will find them.
#
#   scripts/sign-release.sh [version]
#
# version defaults to MARKETING_VERSION in the Xcode project. The private key is
# read from $ISLE_PRIVATE_KEY_FILE or ~/.isle-signing/ed25519.key (base64 raw,
# the half of the key baked into UpdaterConfig.publicKeyBase64). Generate one
# with:  swift scripts/isle-sign.swift keygen
#
set -eu

REPO="matthewhamilton3141/isle"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

KEY_FILE="${ISLE_PRIVATE_KEY_FILE:-$HOME/.isle-signing/ed25519.key}"
[ -f "$KEY_FILE" ] || { echo "No signing key at $KEY_FILE — run: swift scripts/isle-sign.swift keygen" >&2; exit 1; }

# Xcode lives behind DEVELOPER_DIR here (xcode-select points at CommandLineTools).
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

VERSION="${1:-$(grep -m1 'MARKETING_VERSION' Isle.xcodeproj/project.pbxproj | sed -E 's/.*= *([0-9][0-9.]*);/\1/')}"
TAG="v$VERSION"
DMG="dist/Isle-$VERSION.dmg"
APP_BUILD="build/Release/Build/Products/Release/Isle.app"

echo "==> Building Release $VERSION"
# `-destination generic/platform=macOS` is what makes the build universal.
# Without it xcodebuild defaults to the *local* machine as the destination and
# narrows ARCHS to that one slice, so an Apple Silicon Mac silently produces an
# arm64-only app that Intel Macs refuse to launch ("not supported on this Mac").
xcodebuild -project Isle.xcodeproj -scheme Isle -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath build/Release build \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
    >/dev/null
[ -d "$APP_BUILD" ] || { echo "build produced no app" >&2; exit 1; }

# Sanity: the built app's version must match what we're signing/advertising.
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_BUILD/Contents/Info.plist")"
[ "$BUILT_VERSION" = "$VERSION" ] || { echo "version mismatch: built $BUILT_VERSION, asked $VERSION" >&2; exit 1; }

# Sanity: both slices must be present. A thin build looks perfectly healthy
# right up until an Intel user downloads it, so fail here instead.
for SLICE in x86_64 arm64; do
    lipo -archs "$APP_BUILD/Contents/MacOS/Isle" | grep -qw "$SLICE" \
        || { echo "not universal: $SLICE slice missing from the app binary" >&2; exit 1; }
done

echo "==> Packaging $DMG"
STAGE="build/dmg-staging"
rm -rf "$STAGE"; mkdir -p "$STAGE" dist
cp -R "$APP_BUILD" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Isle $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> Signing"
PRIV="$(cat "$KEY_FILE")"
SIG="$(swift "$HERE/isle-sign.swift" sign "$PRIV" "$DMG")"

# Self-check with the public half baked into the app, so we never ship a DMG
# the app would reject.
PUB="$(grep -m1 'publicKeyBase64 =' Isle/Update/Updater.swift | sed -E 's/.*"([^"]*)".*/\1/')"
swift "$HERE/isle-sign.swift" verify "$PUB" "$SIG" "$DMG" >/dev/null
echo "    signature verifies against the app's embedded public key"

# The artifact URL points at the tagged release asset (stable per version); the
# manifest itself is fetched from /releases/latest/download/latest.json.
URL="https://github.com/$REPO/releases/download/$TAG/Isle-$VERSION.dmg"
cat > dist/latest.json <<EOF
{
  "version": "$VERSION",
  "notes": "",
  "url": "$URL",
  "signature": "$SIG",
  "minimumSystemVersion": "14.0"
}
EOF

echo ""
echo "Done. Artifacts in dist/:"
echo "  $DMG"
echo "  dist/latest.json"
echo ""
echo "Publish (fill in notes):"
echo "  gh release create $TAG \"$DMG\" dist/latest.json --title \"Isle $VERSION\" --notes \"...\""
echo "  # or, updating an existing release:"
echo "  gh release upload $TAG \"$DMG\" dist/latest.json --clobber"
