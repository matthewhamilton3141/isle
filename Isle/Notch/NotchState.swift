//
//  NotchState.swift
//
//  The three-way visual state from spec 3.1, plus the rule for who wins
//  when both the user's mouse and a Claude Code event want the notch.
//

import SwiftUI

enum NotchState: Equatable {
    /// Resting size, hugging the physical cutout.
    case collapsed

    /// User put the pointer over the notch. Not urgent — collapses again
    /// as soon as the pointer leaves.
    case hoverExpanded

    /// Opened by a Claude Code event rather than the pointer. Must be able
    /// to interrupt `.collapsed` with the mouse nowhere near the notch.
    case liveActivityExpanded

    var isExpanded: Bool {
        self != .collapsed
    }
}

/// Resolves the desired state from the two independent inputs that can
/// open the notch. Kept separate from the view so the precedence rule is
/// testable and stated once.
///
/// Live activities outrank hover: if Claude needs approval while the
/// pointer happens to be elsewhere, the notch still opens, and a hover
/// that ends doesn't close a live activity out from under the user.
enum NotchStateResolver {
    static func resolve(isHovering: Bool, hasLiveActivity: Bool) -> NotchState {
        if hasLiveActivity { return .liveActivityExpanded }
        if isHovering { return .hoverExpanded }
        return .collapsed
    }
}

extension Animation {
    /// Shared open/close curve. A spring rather than an ease so the panel
    /// settles with a little weight — matches the system Dynamic Island feel
    /// the spec asks for. `bounce` kept low; anything higher reads as toylike
    /// at this size.
    static var notch: Animation {
        .spring(response: 0.34, dampingFraction: 0.76, blendDuration: 0)
    }
}
