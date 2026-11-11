//
//  IslandPrism.swift
//
//  The numbers behind Prism (see `PanelBackground.prism`), kept free of
//  AppKit and SwiftUI so they compile on their own and can be checked
//  without an app (scripts/test-island-glass.sh):
//
//  - The lens's shape: the open panel is a lip taller than in every other
//    mode, and rounder at the bottom. The content keeps the room it has
//    everywhere else; the lip is glass with nothing on it but light.
//  - The shade: solid black over the camera housing, easing to a tint the
//    content can be read on, and clearing through the horizon — where the
//    content ends and the lip begins — to all but bare glass.
//  - The ribbon: a streak of light lying along the lip, split into a
//    spectrum. How far the spectrum fans out at each point across the
//    panel is the music's level in one band — bass at the centre, treble
//    toward the tips, mirrored — so the streak's outline is the waveform.
//    Silent, it's a thin white line with colour only at its fringes.
//
//  The drawing is in IslandPrism+SwiftUI.swift and PrismRibbonView.swift.
//

import CoreGraphics
import Foundation

enum IslandPrism {
    // MARK: - The lens's shape

    /// How much taller the open panel is in Prism: clear glass below the
    /// content, where the ribbon lies. Tune here.
    static let lip: CGFloat = 30

    /// The open panel's bottom corners in Prism: rounder than the other
    /// modes' 22, so the lip reads as the thick edge of a lens. Tune here.
    static let bottomCornerRadius: CGFloat = 34

    // MARK: - The shade

    /// Black over the glass across the panel's whole width once the ease
    /// from the band has run: what the glass at the side walls keeps.
    /// Tune here.
    static let edgeTint: Double = 0.25

    /// Black laid behind the content on top of that, inset from the walls
    /// with a soft edge, so text sits on `contentAlpha` while the walls stay
    /// lighter glass. The glass under it is frosted there (`PrismFrost`),
    /// so this only has to darken, not hide. Tune here.
    static let scrim: Double = 0.3

    /// How far inside the glass's walls the scrim's edge sits, and its
    /// feather, in points.
    static let scrimInset: CGFloat = 5
    static let scrimFeather: CGFloat = 6

    /// Black left over the lip: all but bare glass. It lies over the ribbon
    /// too, which is in the glass under it, so what the ribbon needs to
    /// shine against over a white window is its own bed of shade
    /// (`ribbonBed`), not this. Tune here.
    static let lipTint: Double = 0.1

    /// The horizon: how many points the shade takes to clear from the
    /// content's tint to the lip's, centred on the line where the content's
    /// bottom inset ends and the lip begins.
    static let horizonFeather: CGFloat = 18

    /// How much of the way from the band's foot to the horizon the ease
    /// from solid black takes; past it the shade is `edgeTint` down to the
    /// horizon.
    static let reach: Double = 0.45

    /// Black over the glass where the content sits: the shade and the
    /// scrim composited.
    static var contentAlpha: Double { IslandGlass.over(edgeTint, scrim) }

    /// The shade's black at `y` points from the top of a panel `height`
    /// tall (lip included) whose solid band is `band` deep, without the
    /// scrim: 1 down to the band's foot, eased to `edgeTint`, held to the
    /// horizon, and cleared to `lipTint` across it.
    static func shadeAlpha(y: CGFloat, height: CGFloat, band: CGFloat) -> Double {
        guard y > band else { return 1 }
        let horizonTop = height - lip - horizonFeather / 2
        let horizonBottom = height - lip + horizonFeather / 2
        if y >= horizonBottom { return lipTint }
        if y > horizonTop {
            let t = Double((y - horizonTop) / horizonFeather)
            return edgeTint + (lipTint - edgeTint) * IslandGlass.fadeEase(t)
        }
        let span = horizonTop - band
        guard span > 0 else { return 1 }
        return 1 - (1 - edgeTint) * IslandGlass.fadeEase(Double((y - band) / span) / reach)
    }

    /// The ease below the band as (location, alpha) stops, location 0 at
    /// the band's foot and 1 at the top of the horizon.
    static func shadeStops() -> [(location: Double, alpha: Double)] {
        let n = IslandGlass.fadeStopCount
        let ease = (0...n).map {
            let t = Double($0) / Double(n)
            return (t * reach, 1 - (1 - edgeTint) * IslandGlass.fadeEase(t))
        }
        return reach < 1 ? ease + [(1, edgeTint)] : ease
    }

    /// The horizon as (location, alpha) stops, top to bottom.
    static func horizonStops() -> [(location: Double, alpha: Double)] {
        let n = 8
        return (0...n).map {
            let t = Double($0) / Double(n)
            return (t, edgeTint + (lipTint - edgeTint) * IslandGlass.fadeEase(t))
        }
    }

    // MARK: - The ribbon

    /// The strip the ribbon is drawn in, measured up from the panel's
    /// bottom edge: the lip, and room above it for the spectrum's upper
    /// half to fade out behind the content's bottom inset.
    static let ribbonStrip: CGFloat = 58

    /// The ribbon's centre line, in points above the panel's bottom edge:
    /// a little above the lip's middle, where the lens is at its clearest
    /// and the rim's own highlight doesn't crowd it.
    static let ribbonCentre: CGFloat = 17

    /// How far in from the glass's side walls the ribbon's tips sit.
    static let ribbonInset: CGFloat = 26

    /// The fan at rest and at a full level, in points either side of the
    /// centre line: red at the top of it, violet at the bottom. At rest
    /// the colours all but coincide and the streak is white; a loud band
    /// spreads them across most of the lip. Tune here.
    static let restSpread: Double = 1.1
    static let fullSpread: Double = 11.5

    /// Each colour's own softness, as a Gaussian's width in points: at
    /// rest, and what a point of spread adds.
    static let restSigma: Double = 1.05
    static let sigmaPerSpread: Double = 0.2

    /// The streak's brightness at rest, as a fraction of its brightness at
    /// a full level: a lens catching a little light, not a lamp. Tune here.
    static let restGlow: Double = 0.5

    /// How much of its own light the ribbon covers what's under it with, 0
    /// (pure added light, invisible over white) to 1, and the shade it
    /// lies on at full brightness, as black's alpha. Tune here.
    static let ribbonCover: Double = 1.0
    static let ribbonBed: Double = 0.7

    /// How many points across the panel the profile is sampled at for the
    /// drawing. The shader interpolates between them.
    static let ribbonColumns = 64

    /// How much of the way from the centre to a tip the bands are laid
    /// over: bass at the centre, the top band here, and the rest of the
    /// way out only the taper.
    static let bandSpan: Double = 0.86

    /// 0 at the ribbon's centre, 1 at either tip, for `u` 0...1 across it.
    static func mirrored(_ u: Double) -> Double {
        abs(2 * min(max(u, 0), 1) - 1)
    }

    /// The streak's taper: 1 at the centre, 0 at the tips, a lens's
    /// outline — full for most of its length and drawn to a point.
    static func taper(_ u: Double) -> Double {
        let m = mirrored(u)
        return pow(1 - pow(m, 2.4), 1.5)
    }

    /// The level at `u` across the ribbon, from `bands` (0...1 each, bass
    /// first): the bands laid from the centre outward and mirrored, eased
    /// from one to the next so the outline has no corners. No bands is
    /// silence.
    static func level(at u: Double, bands: [Double]) -> Double {
        guard !bands.isEmpty else { return 0 }
        let p = min(mirrored(u) / bandSpan, 1) * Double(bands.count - 1)
        let i = min(Int(p), bands.count - 1)
        let j = min(i + 1, bands.count - 1)
        let a = min(max(bands[i], 0), 1), b = min(max(bands[j], 0), 1)
        return a + (b - a) * IslandGlass.fadeEase(p - Double(i))
    }

    /// The fan's half-height at `u`, in points.
    static func spread(at u: Double, bands: [Double]) -> Double {
        taper(u) * (restSpread + (fullSpread - restSpread) * level(at: u, bands: bands))
    }

    /// The streak's brightness at `u`, 0...1.
    static func glow(at u: Double, bands: [Double]) -> Double {
        let lift = min(level(at: u, bands: bands) * 1.25, 1)
        return pow(taper(u), 0.6) * (restGlow + (1 - restGlow) * lift)
    }

    /// The profile the drawing takes: spread and brightness at
    /// `ribbonColumns` points across the ribbon.
    static func profile(bands: [Double]) -> (spread: [Float], glow: [Float]) {
        var s = [Float](repeating: 0, count: ribbonColumns)
        var g = [Float](repeating: 0, count: ribbonColumns)
        for k in 0..<ribbonColumns {
            let u = Double(k) / Double(ribbonColumns - 1)
            s[k] = Float(spread(at: u, bands: bands))
            g[k] = Float(glow(at: u, bands: bands))
        }
        return (s, g)
    }

    // MARK: - The ribbon's motion

    /// How fast a band follows the music up and lets go of it, as time
    /// constants in seconds. The capture publishes about thirty levels a
    /// second, already smoothed for six bars; this carries them between
    /// publishes at the display's rate. Tune here.
    static let attack: Double = 0.05
    static let release: Double = 0.14

    /// A band's next value, `dt` seconds on, on its way to `target`.
    static func follow(_ value: Double, toward target: Double, dt: Double) -> Double {
        let tau = target > value ? attack : release
        guard dt > 0, tau > 0 else { return value }
        return value + (target - value) * (1 - exp(-dt / tau))
    }

    /// Closer than this to their targets, the bands are there: the ribbon
    /// stops drawing until something changes.
    static let settled: Double = 0.002

    /// The pattern when the waveform is set to Animated (no capture), or
    /// the capture has nothing to say: each band its own slow sine, the
    /// frequencies the bars use so the two never disagree about the beat
    /// they aren't following. `t` in seconds.
    static func procedural(band: Int, at t: Double) -> Double {
        let frequencies: [Double] = [1.00, 1.37, 0.83, 1.61, 1.13, 0.71]
        let phases: [Double] = [0.0, 0.9, 1.8, 0.45, 2.3, 1.35]
        let f = frequencies[band % frequencies.count], p = phases[band % phases.count]
        return 0.18 + (sin(t * f * 3.1 + p) + 1) / 2 * 0.62
    }
}
