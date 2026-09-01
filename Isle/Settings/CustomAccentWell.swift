//
//  CustomAccentWell.swift
//
//  The "pick your own" chip at the end of the accent row.
//
//  SwiftUI's `ColorPicker` can't be used here. Its well carries a minimum
//  intrinsic width of roughly 44pt that a `.frame(width:)` won't shrink, so it
//  stretched the row and sat visibly wider and shorter than the 24pt swatches
//  beside it. This draws a chip at exactly the swatch size and opens
//  `NSColorPanel` itself — the same panel `ColorPicker` would have opened, so
//  nothing is lost but the sizing.
//
//  Unselected, the chip shows a hue wheel rather than a colour: it is an
//  invitation to choose, not a colour you have chosen, and the wheel is the
//  convention macOS uses for exactly that. Once it's the active accent it
//  shows the chosen colour, so the row reads uniformly — every chip displays
//  what picking it would give you.
//

import SwiftUI
import AppKit

struct CustomAccentWell: View {
    @Binding var hex: String
    var isSelected: Bool
    var size: CGFloat
    /// Called after a colour is picked, so the caller can make this the active
    /// accent — otherwise the choice would be stored and never applied.
    var onPick: () -> Void

    private static let corner: CGFloat = 5

    /// A full turn of hue. The first and last stops land on the same colour so
    /// the wheel closes without a seam.
    private static let wheel = AngularGradient(
        colors: (0...12).map {
            Color(hue: Double($0) / 12, saturation: 0.85, brightness: 0.95)
        },
        center: .center
    )

    var body: some View {
        Button(action: present) {
            shape
                .frame(width: size, height: size)
                .overlay {
                    RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                        .strokeBorder(.primary.opacity(0.15), lineWidth: 1)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
                        .padding(-3)
                }
        }
        .buttonStyle(.plain)
        .help("Custom colour")
        .accessibilityLabel("Custom colour")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var shape: some View {
        let rect = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        if isSelected {
            rect.fill(Color(hex: hex))
        } else {
            rect.fill(Self.wheel)
        }
    }

    private func present() {
        AccentColorPanel.shared.present(initial: Color(hex: hex)) { picked in
            hex = picked.hexString
            onPick()
        }
    }
}

/// Drives the shared colour panel for the accent well.
///
/// `NSColorPanel` is a process-wide singleton with a single target, so this
/// claims it on each present rather than holding it — SwiftUI's own
/// `ColorPicker` (still used by the Marker Editor) takes it back the same way
/// the next time it is opened.
@MainActor
final class AccentColorPanel: NSObject {
    static let shared = AccentColorPanel()

    private var onChange: ((Color) -> Void)?

    func present(initial: Color, onChange: @escaping (Color) -> Void) {
        self.onChange = onChange

        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = NSColor(initial)
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        onChange?(Color(sender.color))
    }
}
