//
//  DisplayScope.swift
//
//  Which screens the island draws on. Deliberately a binary rather than a
//  display picker: the island is the Mac's status surface, so the only two
//  answers that matter are "the one built into the machine" and "wherever I
//  happen to be looking". Picking a specific external display would mean
//  persisting a stable display identity across reconnects, which macOS makes
//  surprisingly hard (`CGDirectDisplayID` is reassigned on hotplug), for a
//  choice almost nobody would make differently from `.all`.
//

import Foundation

enum DisplayScope: String, CaseIterable, Identifiable {
    /// The built-in panel only — today's behaviour, and the default. Falls
    /// back to the main display when there is no built-in one to use (a
    /// clamshelled MacBook, a Mac mini), so this never means "nowhere".
    case builtIn

    /// One island on every attached display, all showing the same thing.
    /// Mirrored secondaries are skipped — they already show the primary's.
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .builtIn: return "Built-in display"
        case .all: return "All displays"
        }
    }

    var subtitle: String {
        switch self {
        case .builtIn:
            return "The island lives on the Mac's own screen, in the notch. On a Mac with no built-in display it uses the main one."
        case .all:
            return "An island at the top of every attached display, all showing the same thing. Displays without a notch get the rounded pill instead."
        }
    }
}
