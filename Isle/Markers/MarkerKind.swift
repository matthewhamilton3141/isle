//
//  MarkerKind.swift
//
//  The full catalogue of things Isle might surface about a Claude Code
//  session — the current lifecycle states plus every event that could
//  plausibly pop up (errors, questions, limits, …). Each kind gets a
//  designable dot-matrix marker (see MarkerDesign / MarkerEditorView).
//
//  Only a subset is wired to live triggers today (the ones the status file
//  reports — see ClaudeCodeState). The rest are here so their markers can be
//  designed up front, ready for when the hook bridge learns to emit them.
//

import Foundation

enum MarkerCategory: String, CaseIterable, Identifiable {
    case lifecycle
    case attention
    case error
    case status

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lifecycle: return "Lifecycle"
        case .attention: return "Needs you"
        case .error: return "Errors"
        case .status: return "Status"
        }
    }
}

enum MarkerKind: String, CaseIterable, Identifiable, Codable {
    // Lifecycle — driven live today via ClaudeCodeState.
    case disconnected
    case idle
    case working
    case done

    // Needs the user.
    case needsApproval
    case needsQuestion
    case planReview

    // Errors / failures.
    case apiError
    case serverError
    case rateLimited
    case networkOffline

    // Other status that can pop up.
    case waitingInput
    case success
    case warning
    case compacting
    case paused

    var id: String { rawValue }

    var category: MarkerCategory {
        switch self {
        case .disconnected, .idle, .working, .done:
            return .lifecycle
        case .needsApproval, .needsQuestion, .planReview:
            return .attention
        case .apiError, .serverError, .rateLimited, .networkOffline:
            return .error
        case .waitingInput, .success, .warning, .compacting, .paused:
            return .status
        }
    }

    var title: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .idle: return "Idle"
        case .working: return "Working"
        case .done: return "Done"
        case .needsApproval: return "Approve edit"
        case .needsQuestion: return "Question"
        case .planReview: return "Plan review"
        case .apiError: return "API error"
        case .serverError: return "Server error"
        case .rateLimited: return "Rate limited"
        case .networkOffline: return "Offline"
        case .waitingInput: return "Waiting for input"
        case .success: return "Success"
        case .warning: return "Warning"
        case .compacting: return "Compacting"
        case .paused: return "Paused"
        }
    }

    /// One line on what this marker means / what would trigger it.
    var detail: String {
        switch self {
        case .disconnected: return "No active Claude Code session."
        case .idle: return "Session ready, nothing happening."
        case .working: return "Claude is actively doing something."
        case .done: return "Claude finished responding."
        case .needsApproval: return "Claude wants to run a tool or apply an edit."
        case .needsQuestion: return "Claude asked you a question."
        case .planReview: return "A plan is ready for you to review."
        case .apiError: return "The API returned an error."
        case .serverError: return "A 5xx / overloaded response."
        case .rateLimited: return "Usage or rate limit reached."
        case .networkOffline: return "No network connection."
        case .waitingInput: return "Waiting on you to type."
        case .success: return "A task completed successfully."
        case .warning: return "Something needs attention, non-blocking."
        case .compacting: return "Compacting the conversation context."
        case .paused: return "Session paused."
        }
    }

    /// The lifecycle kind for a live status, so the notch can map the state
    /// it reads from the hook bridge onto a designed marker.
    init(state: ClaudeCodeState) {
        switch state {
        case .disconnected: self = .disconnected
        case .idle: self = .idle
        case .working: self = .working
        case .needsApproval: self = .needsApproval
        case .needsQuestion: self = .needsQuestion
        case .waitingInput: self = .waitingInput
        case .done: self = .done
        // The specific failure kind (rate limited / server error / …) is chosen
        // from `error_type` on the view model; the lifecycle mapping just needs
        // a sensible default marker.
        case .failed: self = .apiError
        }
    }
}
