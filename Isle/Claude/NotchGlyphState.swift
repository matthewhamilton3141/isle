//
//  NotchGlyphState.swift
//
//  Maps Claude Code's lifecycle state (from the hook bridge — see the
//  build spec's Section 3.3) to the breathing glyph's visual parameters.
//  Single source of truth for both BreathingShapeView (SwiftUI/Canvas)
//  and BreathingShapeLayer (AppKit/CA), so tuning the feel later only
//  means editing this file.
//

import SwiftUI
import AppKit

enum ClaudeCodeState: Equatable {
    case disconnected
    case idle
    case working
    case needsApproval
    case needsQuestion
    case waitingInput
    case done

    /// States that warrant interrupting the user — opening the notch and
    /// taking over the collapsed island. Approval and questions qualify;
    /// idle-waiting is calmer and stays ambient.
    var isAttention: Bool {
        self == .needsApproval || self == .needsQuestion
    }
}

struct GlyphConfig: Equatable {
    var period: Double
    var minScale: CGFloat
    var maxScale: CGFloat
    var minOpacity: Double
    var maxOpacity: Double
    var color: Color
    var nsColor: NSColor   // kept alongside `color` since BreathingShapeLayer wants NSColor, not SwiftUI Color

    static func config(for state: ClaudeCodeState) -> GlyphConfig {
        switch state {
        case .disconnected:
            return GlyphConfig(period: 3.2, minScale: 0.9, maxScale: 1.0, minOpacity: 0.25, maxOpacity: 0.4,
                                color: .gray, nsColor: .secondaryLabelColor)
        case .idle:
            return GlyphConfig(period: 2.4, minScale: 0.88, maxScale: 1.0, minOpacity: 0.45, maxOpacity: 0.7,
                                color: .gray, nsColor: .labelColor)
        case .working:
            return GlyphConfig(period: 1.6, minScale: 0.85, maxScale: 1.0, minOpacity: 0.55, maxOpacity: 1.0,
                                color: .orange, nsColor: .systemOrange)
        case .needsApproval:
            // Faster + brighter than `working` — this is the interrupt case,
            // it should read as urgent at a glance in the collapsed notch.
            return GlyphConfig(period: 0.8, minScale: 0.8, maxScale: 1.05, minOpacity: 0.6, maxOpacity: 1.0,
                                color: .red, nsColor: .systemRed)
        case .done:
            // Not actually used for the breathing loop — `done` renders via
            // CheckmarkBurstView instead (see ClaudeStatusGlyphView.swift).
            // Kept here only as a sane resting color if you land on `.done`
            // without going through the one-shot transition, e.g. a stale
            // status file read on app launch.
            return GlyphConfig(period: 1.6, minScale: 0.95, maxScale: 1.0, minOpacity: 0.8, maxOpacity: 1.0,
                                color: .green, nsColor: .systemGreen)
        default:
            // needsQuestion / waitingInput — this legacy config is unused now
            // (markers render via DotMatrixView), so a neutral fallback is fine.
            return GlyphConfig(period: 1.4, minScale: 0.85, maxScale: 1.0, minOpacity: 0.55, maxOpacity: 1.0,
                                color: .blue, nsColor: .systemBlue)
        }
    }
}
