//
//  StatusLight.swift
//
//  The status light: Fade's light — the rim, the glint and its haze, the
//  sweep, and the closed island's lit edge and waveform — taking Claude's
//  status colour, blended with the current cover's. When Claude needs you,
//  is done or is stopped, the light wraps the whole outline instead of
//  running along its lower edge, and approval and a question pulse gently,
//  done flashes once.
//
//  The rules and the arithmetic, free of AppKit and SwiftUI so they compile
//  on their own for scripts/test-status-light.sh. The drawing is in
//  StatusLight+SwiftUI.swift and IslandGlass+SwiftUI.swift.
//

import Foundation

/// What the light says about Claude. No status (idle, no session, paused)
/// is nil: the light is the cover's alone.
enum StatusLightKind: String, CaseIterable, Equatable {
    case working
    case approval
    case question
    case done
    /// A usage limit or an error: Claude stopped and can't go on by itself.
    case limit

    /// The status for a marker (`MarkerKind`'s raw value), or nil for one
    /// that isn't news: idle, waiting at the prompt, no session, paused.
    static func forMarker(_ raw: String) -> StatusLightKind? {
        switch raw {
        case "working", "compacting": return .working
        case "needsApproval", "planReview": return .approval
        case "needsQuestion": return .question
        case "done", "success": return .done
        case "rateLimited", "apiError", "serverError", "networkOffline": return .limit
        default: return nil
        }
    }

    /// The status's colour, as sRGB hex: working purple, approval amber, a
    /// question blue, done green, a limit or error red.
    var defaultHex: String {
        switch self {
        case .working: return "#C47DFF"
        case .approval: return "#FFB21F"
        case .question: return "#55A3FF"
        case .done: return "#34D27B"
        case .limit: return "#FF5B5B"
        }
    }

    /// The status's marker (`MarkerKind`'s raw value).
    var marker: String {
        switch self {
        case .working: return "working"
        case .approval: return "needsApproval"
        case .question: return "needsQuestion"
        case .done: return "done"
        case .limit: return "rateLimited"
        }
    }

    /// The light runs the whole outline — up the sides to the top — rather
    /// than its lower edge: Claude needs you, is finished, or is stopped.
    /// Working stays on the lower edge, like no status.
    var wraps: Bool { self != .working }

    /// How the light moves.
    var motion: StatusLightMotion {
        switch self {
        case .approval, .question: return .pulse
        case .done: return .flash
        case .working, .limit: return .still
        }
    }

    /// The small symbol after the closed island's waveform, for the states
    /// that want you to look (an SF Symbol name), or nil.
    var symbol: String? {
        switch self {
        case .approval: return "exclamationmark"
        case .question: return "questionmark"
        case .done: return "checkmark"
        case .limit: return "clock"
        case .working: return nil
        }
    }
}

enum StatusLightMotion: Equatable {
    case still
    /// A gentle, endless breathing of the light's opacity.
    case pulse
    /// One flash when the status arrives, then still.
    case flash
}

enum StatusLight {
    /// How far the light goes from the cover's colours toward the status
    /// colour: mostly the status, with the cover still in it. Tune here.
    static let mix: Double = 0.7

    /// The pulse: the light's opacity between `pulseLow` and 1 and back,
    /// over `pulsePeriod` seconds, eased — a breath, not a blink. Run by
    /// Core Animation, so it costs the app nothing per frame.
    static let pulseLow: Double = 0.62
    static let pulsePeriod: Double = 2.0
    /// The frames a second the pulse asks the window server for: plenty for
    /// a slow breath, a fraction of the display's rate. Tune here.
    static let pulseFrameRate: Double = 15

    /// The flash: a brighter copy of the light up to `flashPeak` and away
    /// again over `flashDuration` seconds, once, when done arrives.
    static let flashPeak: Double = 0.9
    static let flashDuration: Double = 0.9
    /// When in the flash it peaks, as a fraction: quick up, slow away.
    static let flashRise: Double = 0.18

    /// The wrapped rim's strength along the whole outline (added light).
    static let wrapAlpha: Double = 0.85

    /// How far below the screen's top edge the wrapped rim starts, in
    /// points: the outline's top runs along the screen's edge, and lit
    /// there it would read as a line across the top of the display.
    static let wrapTopClearance: Double = 2

    /// The rim's white tinted toward the status colour by this much, on the
    /// open panel's lower edge (the wrap is the status colour outright).
    static let rimTint: Double = 0.55

    /// The closed island's lit lower edge: its strength, and how far in
    /// from each end it fades from nothing.
    static let edgeAlpha: Double = 0.85
    static let edgeFade: Double = 0.16

    /// The status icon on the closed island: its slot's width and the gap
    /// before it, in points — what the island grows by to fit it.
    static let iconSlot: Double = 12
    static let iconGap: Double = 5
    static var iconWidth: Double { iconSlot + iconGap }

    /// A colour as sRGB, each 0...1.
    struct RGB: Equatable {
        var r: Double
        var g: Double
        var b: Double

        init(_ r: Double, _ g: Double, _ b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }

        /// "#RRGGBB" (or "RRGGBB"); nil if it isn't one.
        init?(hex: String) {
            var s = hex.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("#") { s.removeFirst() }
            guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
            self.init(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
        }

        /// This colour `t` of the way to `other`.
        func mixed(toward other: RGB, by t: Double) -> RGB {
            let u = min(max(t, 0), 1)
            return RGB(r + (other.r - r) * u, g + (other.g - g) * u, b + (other.b - b) * u)
        }
    }

    /// A light colour from the cover (already lit by `IslandGlass.fadeLight`),
    /// taken `mix` of the way to the status colour; the cover's alone with
    /// no status.
    static func blend(_ cover: RGB, status: RGB?) -> RGB {
        guard let status else { return cover }
        return cover.mixed(toward: status, by: mix)
    }

    /// The pulse's opacity at `t` seconds into it: 1 at the start, down to
    /// `pulseLow` half a period in, back to 1 — a cosine, so it never jolts.
    static func pulseOpacity(at t: Double) -> Double {
        let phase = (t / pulsePeriod).truncatingRemainder(dividingBy: 1)
        return pulseLow + (1 - pulseLow) * (0.5 + 0.5 * cos(2 * Double.pi * phase))
    }

    /// The flash's opacity at `t` seconds after done arrived: up to the peak
    /// by `flashRise` of the way, then eased back to nothing by the end.
    static func flashOpacity(at t: Double) -> Double {
        guard t > 0, t < flashDuration else { return 0 }
        let u = t / flashDuration
        if u < flashRise { return flashPeak * IslandGlass.fadeEase(u / flashRise) }
        return flashPeak * (1 - IslandGlass.fadeEase((u - flashRise) / (1 - flashRise)))
    }
}
