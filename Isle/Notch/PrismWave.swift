//
//  PrismWave.swift
//
//  What moves Prism's ribbon when it is drawn as a wave
//  (`IslandPrism.RibbonStyle.wave`): the motion of Matthew's Glasswave,
//  without its orb.
//
//  The wave is three ribbons of light, one each for the bass, the mids and
//  the treble. Each is the space between two travelling sine curves, and
//  what the sound changes is how tall each ribbon stands and how fast the
//  curves travel:
//
//  - A ribbon's height is a mass on a loose spring, pulled toward its
//    band's level. Loose, so a hit overshoots and settles: that is what
//    makes the wave move like liquid rather than like a meter.
//  - A band's pull is mostly its hits — how far this moment stands above
//    the last third of a second — so a drum is a kick in the ribbon and a
//    held note is only a swell.
//  - Louder sound travels faster.
//  - The wave stays open through the gaps between phrases, and closes to
//    a resting streak a little after the sound stops.
//
//  Glasswave closes into an orb with a slow breath in it. Here there is no
//  orb, and a silent ribbon is still: with nothing to follow, everything
//  settles, and the ribbon stops being drawn until something changes
//  (`isMoving`).
//
//  Kept free of AppKit and SwiftUI so it compiles on its own for
//  scripts/test-island-glass.sh. The drawing is the `wave` function of the
//  shader in PrismRibbonView.swift.
//

import Foundation

enum PrismWave {
    /// What the sound is doing right now, each value 0...1: how loud it is
    /// overall, and the bass, the mids and the treble.
    struct Features: Equatable {
        var level: Double = 0
        var bands: [Double] = [0, 0, 0]
    }

    // MARK: - Reading the bands

    /// How long a band's own recent past is, in seconds: what a moment has
    /// to stand above to count as a hit.
    static let punchMemory: Double = 0.35

    /// A band's pull on its ribbon: this much of where it is, and this
    /// much of how far it stands above its recent past.
    static let held: Double = 0.5
    static let punch: Double = 1.5

    /// Turns the island's band levels (six, low to high, each already
    /// measured against its own recent peak by the capture) into the
    /// wave's three, with the hits brought out.
    struct Shaper {
        private var slow: [Double] = [0, 0, 0]

        /// The features of `bands` now, `dt` seconds after the last call.
        mutating func features(of bands: [Double], dt: Double) -> Features {
            let now = PrismWave.groups(bands)
            var out = Features()
            out.level = (now[0] + now[1] + now[2]) / 3
            let ease = dt > 0 ? 1 - exp(-dt / PrismWave.punchMemory) : 0
            for i in 0..<3 {
                slow[i] += (now[i] - slow[i]) * ease
                let hit = max(0, now[i] - slow[i])
                out.bands[i] = min(1, PrismWave.held * now[i] + PrismWave.punch * hit)
            }
            return out
        }

        /// The features of levels that have always been what they are: no
        /// hits, only where they stand. For a ribbon drawn at fixed levels.
        static func standing(_ bands: [Double]) -> Features {
            let now = PrismWave.groups(bands)
            return Features(
                level: (now[0] + now[1] + now[2]) / 3,
                bands: now.map { min(1, PrismWave.held * $0) }
            )
        }
    }

    /// The bands as bass, mids and treble: each the louder of a pair, so a
    /// kick in either low band moves the bass ribbon. Fewer than six fold
    /// the same way.
    static func groups(_ bands: [Double]) -> [Double] {
        func band(_ k: Int) -> Double { k < bands.count ? min(max(bands[k], 0), 1) : 0 }
        return [max(band(0), band(1)), max(band(2), band(3)), max(band(4), band(5))]
    }

    // MARK: - The motion

    /// A mass on a spring. Low damping lets it overshoot and settle.
    struct Spring: Equatable {
        var x: Double = 0
        var v: Double = 0

        mutating func step(to target: Double, frequency: Double, damping: Double, dt: Double) {
            let w = 2 * Double.pi * frequency
            v += (w * w * (target - x) - 2 * damping * w * v) * dt
            x += v * dt
        }
    }

    /// How fast the overall level is followed, per second: up at once,
    /// down slowly.
    static let levelRise: Double = 60
    static let levelFall: Double = 7

    /// Louder than this is sound; and how long after the last of it the
    /// wave stays open, in seconds — through the gaps between words and
    /// between beats.
    static let soundFloor: Double = 0.04
    static let openHold: Double = 1.1

    /// The spring the wave opens and closes on.
    static let openFrequency: Double = 1.5
    static let openDamping: Double = 0.9

    /// A ribbon's height with nothing pulling on it: the resting streak's.
    static let restAmp: Double = 0.12
    /// How much an open wave's ribbons breathe about that on their own,
    /// and the thin body they keep, so the wave never vanishes mid-song.
    static let breath: Double = 0.04
    static let body: Double = 0.08
    /// What the overall level and a ribbon's own band add to its height.
    static let levelPull: Double = 0.22
    static let bandPull: Double = 0.90

    /// The ribbons' springs: the bass slowest, the treble quickest; all
    /// loose.
    static let ampFrequency: Double = 5.5
    static let ampFrequencyStep: Double = 1.5
    static let ampDamping: Double = 0.5

    /// How fast the curves travel, in radians a second: an open wave's
    /// drift, and what a full level adds to it.
    static let drift: Double = 0.6
    static let levelSpeed: Double = 3.6

    /// The phase comes round after this much: every multiple of it the
    /// shader takes (0.8, -0.7, 1.15, 1.3, -0.9) is then a whole number of
    /// turns, so wrapping it changes nothing drawn. Likewise the clock,
    /// for the shader's slow sways (0.31, 0.23, 0.41) and the breath here
    /// (0.8).
    static let phaseWrap: Double = 40 * Double.pi
    static let clockWrap: Double = 200 * Double.pi

    /// The wave's state, stepped once a frame.
    struct Motion: Equatable {
        private(set) var time: Double = 0
        /// The clock the ribbons breathe and sway on: it runs only while
        /// the wave is open and travelling, so a resting ribbon, or one
        /// that is held still, doesn't drift.
        private(set) var clock: Double = 0
        private(set) var phase: Double = 0
        private(set) var level: Double = 0
        private(set) var open = Spring()
        private(set) var amps = [Spring](repeating: Spring(x: PrismWave.restAmp), count: 3)
        private var lastSound: Double = -10
        /// Whether the last step left anything still on its way.
        private(set) var isMoving = false

        /// How open the wave is, 0 the resting streak to 1.
        var openness: Double { min(max(open.x, 0), 1) }

        /// `frame` seconds on, following `input`. With `travels` false the
        /// curves stay where they are and the ribbons don't breathe: they
        /// only stand as tall as the sound has them (Reduce Motion, and a
        /// status that is meant to hold still).
        mutating func step(dt frame: Double, input f: Features, travels: Bool = true) {
            var remaining = min(max(frame, 0), 0.1)
            let h = 1.0 / 240.0
            var rate = 0.0
            var target = [Double](repeating: PrismWave.restAmp, count: 3)
            while remaining > 1e-6 {
                let dt = min(h, remaining)
                remaining -= dt
                time += dt

                // Rise fast, fall slowly.
                let follow = f.level > level ? PrismWave.levelRise : PrismWave.levelFall
                level += (f.level - level) * (1 - exp(-follow * dt))

                // Stay open through the gaps.
                if f.level > PrismWave.soundFloor { lastSound = time }
                let wantOpen: Double = (time - lastSound) < PrismWave.openHold ? 1 : 0
                open.step(to: wantOpen, frequency: PrismWave.openFrequency, damping: PrismWave.openDamping, dt: dt)
                let o = openness
                if travels { clock += dt * o }

                for i in 0..<3 {
                    // Mostly the band's own hits, a little of the overall
                    // loudness, and, while the wave is open, a thin body
                    // that breathes.
                    let sway = travels ? PrismWave.breath * sin(clock * 0.8 + Double(i) * 2.1) : 0
                    target[i] = PrismWave.restAmp + o * (sway + PrismWave.body)
                        + PrismWave.levelPull * f.level + PrismWave.bandPull * f.bands[i]
                    amps[i].step(
                        to: target[i],
                        frequency: PrismWave.ampFrequency + Double(i) * PrismWave.ampFrequencyStep,
                        damping: PrismWave.ampDamping,
                        dt: dt
                    )
                }

                // Louder sound travels faster; a closed wave doesn't travel.
                rate = travels ? PrismWave.drift * o + PrismWave.levelSpeed * level : 0
                phase += dt * rate
            }
            if phase >= PrismWave.phaseWrap { phase -= PrismWave.phaseWrap }
            if time >= PrismWave.clockWrap {
                time -= PrismWave.clockWrap
                lastSound -= PrismWave.clockWrap
            }
            if clock >= PrismWave.clockWrap { clock -= PrismWave.clockWrap }

            let wantOpen: Double = (time - lastSound) < PrismWave.openHold ? 1 : 0
            var moving = rate > 1e-4
                || abs(f.level - level) > PrismWave.still
                || abs(open.x - wantOpen) > PrismWave.still || abs(open.v) > PrismWave.still
                // Open with nothing playing: it has yet to close.
                || (wantOpen == 1 && f.level <= PrismWave.soundFloor && travels)
            for i in 0..<3 where abs(amps[i].x - target[i]) > PrismWave.still || abs(amps[i].v) > PrismWave.still * 4 {
                moving = true
            }
            isMoving = moving
        }

        /// The wave as it would stand had `f` always been the sound: for a
        /// ribbon drawn at fixed levels, and the tests.
        static func standing(_ f: Features) -> Motion {
            var m = Motion()
            m.level = f.level
            m.open.x = f.level > PrismWave.soundFloor ? 1 : 0
            for i in 0..<3 {
                m.amps[i].x = PrismWave.restAmp + m.open.x * PrismWave.body
                    + PrismWave.levelPull * f.level + PrismWave.bandPull * f.bands[i]
            }
            // Somewhere the three ribbons aren't all crossing at once.
            m.phase = 1.2
            return m
        }
    }

    /// Nearer than this to where it is going, and slower, a value has
    /// arrived.
    static let still: Double = 0.002

    // MARK: - The drawing's numbers

    /// One unit of the wave's own measure, in points. Glasswave draws in
    /// units of half its window's height; here a unit is this much, so the
    /// tallest a loud ribbon stands (about four tenths of a unit either side
    /// of the resting line) stays inside the lip. Tune here.
    static let unit: Double = 36

    /// How many times Glasswave's waves fit along the ribbon. Its ribbon
    /// is three or four times as long as it is tall; this one is twelve,
    /// so at 1 the same waves are long and lazy. Tune here.
    static let turns: Double = 1.25

    /// How much of its layer's colour a ribbon takes, 0 white light to 1.
    static let tint: Double = 0.8

    /// How far apart the colours of the light are drawn, in units: what
    /// puts the fringe on every edge. At rest, and what a full level adds.
    /// Wider than Glasswave's, whose window is many times this size.
    static let fringe: Double = 0.034
    static let fringePerLevel: Double = 0.03

    /// A resting ribbon's thickness and an open one's, in units, and what
    /// a full level adds.
    static let restThick: Double = 0.030
    static let openThick: Double = 0.060
    static let thickPerLevel: Double = 0.08

    /// How bright the resting streak is beside an open wave.
    static let restGlow: Double = 0.62
}
