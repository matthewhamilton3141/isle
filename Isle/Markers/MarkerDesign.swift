//
//  MarkerDesign.swift
//
//  The editable design for one marker: which of the 16 dots are lit, how
//  they're coloured, how they animate. Codable so the editor's output
//  persists (MarkerStore) and drives the live notch (DotMatrixView).
//

import SwiftUI
import AppKit

struct MarkerDesign: Codable, Equatable {
    /// Row-major 4x4, index = row * 4 + col. `true` = lit.
    var dots: [Bool]
    var colorMode: ColorMode
    var fixedColorHex: String
    var animation: MarkerAnimation
    /// Animation rate. Higher is faster / more urgent.
    var speed: Double
    /// Overall brightness ceiling, so `idle`/`disconnected` can rest dim.
    var intensity: Double
    /// Draw unlit dots as a faint ghost grid (gives shapes context).
    var ghost: Bool

    enum ColorMode: String, Codable, CaseIterable, Identifiable {
        case palette   // tint from the album artwork, like the waveform
        case fixed     // a single chosen colour

        var id: String { rawValue }
        var title: String { self == .palette ? "Artwork" : "Fixed" }
    }

    enum MarkerAnimation: String, Codable, CaseIterable, Identifiable {
        case solid     // steady, gentle breathe
        case shimmer   // each dot twinkles on its own phase
        case pulse     // all lit dots pulse together
        case blink     // hard on/off
        case motion    // evolving plasma — waves + ripples that keep changing
        case compact   // a full box collapses line by line, then refills

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    /// 5x5. Odd so shapes have a true centre column/row (index = row*5 + col).
    static let dimension = 5
    static let dotCount = 25

    // MARK: - Grid helpers

    static func grid(_ lit: [Int]) -> [Bool] {
        var dots = Array(repeating: false, count: dotCount)
        for i in lit where i >= 0 && i < dotCount { dots[i] = true }
        return dots
    }

    // Common shapes in the 5x5 grid (index = row*5 + col; row/col 0…4).
    //   "!"  centred stem + dot        "?"  hook + dot
    //   "✓"  down-left then up-right    "✕"  both diagonals through centre
    static let exclamation = grid([2, 7, 12, 22])
    static let checkmark = grid([4, 8, 10, 12, 16])
    static let question = grid([1, 2, 3, 8, 12, 22])
    static let cross = grid([0, 4, 6, 8, 12, 16, 18, 20, 24])
    static let lines = grid([0, 1, 2, 3, 4, 10, 11, 12, 13, 14, 20, 21, 22, 23, 24])
    static let underscore = grid([21, 22, 23])
    static let midRow = grid([10, 12, 14])
    static let pauseBars = grid([1, 3, 6, 8, 11, 13, 16, 18, 21, 23])
    static let full = Array(repeating: true, count: dotCount)

    // MARK: - Palette of default colours (hex)

    private enum Hex {
        static let red = "#FF3B30"
        static let amber = "#FF9F0A"
        static let green = "#34C759"
        static let blue = "#0A84FF"
        static let cyan = "#32ADE6"
        static let gray = "#8E8E93"
    }

    // MARK: - Per-kind defaults

    static func `default`(for kind: MarkerKind) -> MarkerDesign {
        switch kind {
        case .disconnected:
            return MarkerDesign(dots: full, colorMode: .fixed, fixedColorHex: Hex.gray,
                                animation: .pulse, speed: 1.0, intensity: 0.18, ghost: true)
        case .idle:
            return MarkerDesign(dots: full, colorMode: .palette, fixedColorHex: Hex.gray,
                                animation: .pulse, speed: 1.6, intensity: 0.45, ghost: true)
        case .working:
            return MarkerDesign(dots: full, colorMode: .palette, fixedColorHex: Hex.blue,
                                animation: .motion, speed: 3.2, intensity: 1.0, ghost: true)
        case .done:
            return MarkerDesign(dots: checkmark, colorMode: .fixed, fixedColorHex: Hex.green,
                                animation: .solid, speed: 2.0, intensity: 1.0, ghost: true)

        case .needsApproval:
            return MarkerDesign(dots: exclamation, colorMode: .fixed, fixedColorHex: Hex.amber,
                                animation: .pulse, speed: 5.0, intensity: 1.0, ghost: true)
        case .needsQuestion:
            return MarkerDesign(dots: question, colorMode: .fixed, fixedColorHex: Hex.blue,
                                animation: .pulse, speed: 3.5, intensity: 1.0, ghost: true)
        case .planReview:
            return MarkerDesign(dots: lines, colorMode: .fixed, fixedColorHex: Hex.cyan,
                                animation: .shimmer, speed: 2.4, intensity: 1.0, ghost: true)

        case .apiError:
            return MarkerDesign(dots: cross, colorMode: .fixed, fixedColorHex: Hex.red,
                                animation: .pulse, speed: 4.0, intensity: 1.0, ghost: true)
        case .serverError:
            return MarkerDesign(dots: cross, colorMode: .fixed, fixedColorHex: Hex.red,
                                animation: .blink, speed: 3.0, intensity: 1.0, ghost: true)
        case .rateLimited:
            return MarkerDesign(dots: exclamation, colorMode: .fixed, fixedColorHex: Hex.amber,
                                animation: .blink, speed: 2.0, intensity: 1.0, ghost: true)
        case .networkOffline:
            return MarkerDesign(dots: cross, colorMode: .fixed, fixedColorHex: Hex.gray,
                                animation: .solid, speed: 1.5, intensity: 0.9, ghost: true)

        case .waitingInput:
            return MarkerDesign(dots: midRow, colorMode: .palette, fixedColorHex: Hex.blue,
                                animation: .shimmer, speed: 1.6, intensity: 1.0, ghost: true)
        case .success:
            return MarkerDesign(dots: checkmark, colorMode: .fixed, fixedColorHex: Hex.green,
                                animation: .pulse, speed: 2.6, intensity: 1.0, ghost: true)
        case .warning:
            return MarkerDesign(dots: exclamation, colorMode: .fixed, fixedColorHex: Hex.amber,
                                animation: .solid, speed: 2.0, intensity: 1.0, ghost: true)
        case .compacting:
            return MarkerDesign(dots: full, colorMode: .palette, fixedColorHex: Hex.cyan,
                                animation: .compact, speed: 2.2, intensity: 0.9, ghost: true)
        case .paused:
            return MarkerDesign(dots: pauseBars, colorMode: .fixed, fixedColorHex: Hex.gray,
                                animation: .solid, speed: 1.0, intensity: 0.7, ghost: true)
        }
    }
}

// MARK: - Color <-> hex

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self = Color(.sRGB, red: r, green: g, blue: b)
    }

    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(
            format: "#%02X%02X%02X",
            Int(round(ns.redComponent * 255)),
            Int(round(ns.greenComponent * 255)),
            Int(round(ns.blueComponent * 255))
        )
    }
}
