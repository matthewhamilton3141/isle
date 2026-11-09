//
//  OptionDescriptions.swift
//
//  How much of an `AskUserQuestion` option's description the notch shows
//  under the question face. Claude writes a description for most options,
//  sometimes a sentence, sometimes a paragraph; whether that is the whole
//  reason to read the option or noise in the way of the labels is a matter
//  of taste, so it's a setting.
//
//  The choice changes each option row's height, and the panel is sized from
//  those heights before it is drawn — see `ClaudePanelLayout`.
//

import Foundation

enum OptionDescriptions: String, CaseIterable, Identifiable {
    /// Each description under its label, wrapped to at most
    /// `ClaudePanelLayout.fullDescriptionLines` lines. The tallest rows; when
    /// the capped panel can't hold them, the longest descriptions shorten,
    /// then all of them move beside their labels as under `.oneLine`, so
    /// every option stays in view (see `ClaudePanelLayout.fit`).
    case full

    /// The description beside the label on the same line, cut off where the
    /// row ends. The default: every option keeps one row's height, so four
    /// always fit under the cap.
    case oneLine

    /// Labels only. The shortest rows and the smallest panel.
    case hidden

    static let `default`: OptionDescriptions = .oneLine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: return "Full"
        case .oneLine: return "One line"
        case .hidden: return "Hidden"
        }
    }
}
