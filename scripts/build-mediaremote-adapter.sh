#!/bin/bash
#
# Builds MediaRemoteAdapter.framework from upstream source into Vendor/,
# alongside the Perl script that drives it. An Xcode build phase copies both
# into the app bundle's Resources/.
#
# Vendor/ rather than somewhere under Isle/ on purpose: Isle/ is a
# file-system synchronized group, and Xcode auto-links any .framework it
# finds in one. Isle must not link this framework — it only passes the path
# to /usr/bin/perl — and a stray link makes the app fail to launch with a
# dyld error.
#
# Why this exists at all: as of roughly macOS 15.4, calling
# MRMediaRemoteGetNowPlayingInfo from a normal third-party app returns an
# empty dictionary — Apple gated the read side of MediaRemote behind an
# entitlement. The adapter works around that by loading the framework
# inside /usr/bin/perl, which is Apple-signed and does hold the
# entitlement, then streaming the results back out as JSON lines.
#
# Upstream: https://github.com/ungive/mediaremote-adapter (BSD-3-Clause)
# Isle only ever invokes it out-of-process by path, so the framework is
# NOT linked into the app — it ships as a plain resource.
#
# Usage: ./scripts/build-mediaremote-adapter.sh

set -euo pipefail

ADAPTER_VERSION="v0.7.6"
ADAPTER_REPO="https://github.com/ungive/mediaremote-adapter.git"
DEPLOYMENT_TARGET="14.0"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO_ROOT/Vendor/mediaremote-adapter"
mkdir -p "$DEST"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Fetching mediaremote-adapter $ADAPTER_VERSION"
git clone --depth 1 --branch "$ADAPTER_VERSION" "$ADAPTER_REPO" "$WORK/src" 2>&1 | tail -1

SRC="$WORK/src"
FRAMEWORK="$DEST/MediaRemoteAdapter.framework"

SOURCES=(
    src/adapter/env.m
    src/adapter/get.m
    src/adapter/globals.m
    src/adapter/keys.m
    src/adapter/now_playing.m
    src/adapter/repeat.m
    src/adapter/seek.m
    src/adapter/send.m
    src/adapter/shuffle.m
    src/adapter/speed.m
    src/adapter/stream.m
    src/adapter/test.m
    src/private/MediaRemote.m
    src/utility/Debounce.m
    src/utility/helpers.m
)

echo "==> Building universal dylib"
rm -rf "$FRAMEWORK"
mkdir -p "$FRAMEWORK/Versions/A/Resources"

# -fvisibility=default is load-bearing: the Perl side resolves these
# symbols by name at runtime, so hiding them breaks the whole bridge.
clang \
    -dynamiclib \
    -fobjc-arc \
    -fvisibility=default \
    -arch arm64 -arch x86_64 \
    -mmacosx-version-min="$DEPLOYMENT_TARGET" \
    -I"$SRC/include" \
    -I"$SRC/src" \
    -framework Foundation \
    -framework AppKit \
    -framework UniformTypeIdentifiers \
    -install_name "@rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter" \
    -o "$FRAMEWORK/Versions/A/MediaRemoteAdapter" \
    "${SOURCES[@]/#/$SRC/}"

echo "==> Assembling framework bundle"
cat > "$FRAMEWORK/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>MediaRemoteAdapter</string>
	<key>CFBundleIdentifier</key>
	<string>com.vandenbe.MediaRemoteAdapter</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>MediaRemoteAdapter</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1</string>
	<key>CFBundleVersion</key>
	<string>0.1.0</string>
</dict>
</plist>
PLIST

ln -sf A "$FRAMEWORK/Versions/Current"
ln -sf Versions/Current/MediaRemoteAdapter "$FRAMEWORK/MediaRemoteAdapter"
ln -sf Versions/Current/Resources "$FRAMEWORK/Resources"

echo "==> Copying Perl driver and license"
cp "$SRC/bin/mediaremote-adapter.pl" "$DEST/mediaremote-adapter.pl"
cp "$SRC/LICENSE" "$DEST/mediaremote-adapter-LICENSE.txt"

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$FRAMEWORK"

echo "==> Verifying"
lipo -info "$FRAMEWORK/Versions/A/MediaRemoteAdapter"
/usr/bin/perl "$DEST/mediaremote-adapter.pl" "$FRAMEWORK" get >/dev/null \
    && echo "OK: adapter responds to 'get'" \
    || echo "WARN: adapter built but 'get' failed (is anything playing?)"

echo "==> Done: $FRAMEWORK"
