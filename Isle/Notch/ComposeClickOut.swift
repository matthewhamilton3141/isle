//
//  ComposeClickOut.swift
//
//  A click on the island outside the Claude face's field that has the keys
//  — a reply, a typed answer, a denial's reason — lets the field go, as Esc
//  does: the draft is kept, the field closes on the panel's spring, and the
//  keys go back to the app that had them. Before this, Esc, a send, or a
//  click in another app were the only ways out, and a click on the panel
//  itself did nothing at all.
//
//  The window tells the click (`NotchWindow.pressObserver`); the field says
//  where it is (`ComposeFieldRegion`); the view model decides
//  (`NotchViewModel.clickedOutsideField`).
//

import AppKit
import SwiftUI

extension NotchWindow {
    /// Lets the field go on a click in this window outside it. Where the
    /// button went down decides: a press in the field that drags out to
    /// select is the field's own. A click on a control still does the
    /// control's job — the field lets go once the control has had the click.
    func watchClicksOutsideComposeFields(_ viewModel: NotchViewModel) {
        pressObserver = { [weak self, weak viewModel] point in
            viewModel?.pressBeganComposing = viewModel?.composing != nil
            guard let self, let viewModel, let kind = viewModel.composing,
                  NotchViewModel.clickOutLetsGo(kind), !self.composeFieldContains(point) else { return nil }
            return { [weak viewModel] in viewModel?.clickedOutsideField(kind) }
        }
    }
}

/// Marks where a field is drawn, so a click there keeps it: placed behind
/// the whole field, capsule and Send included. Takes no clicks itself.
struct ComposeFieldRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Marker() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Marker: NSView {
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            (window as? NotchWindow)?.composeFields.remove(self)
            (newWindow as? NotchWindow)?.composeFields.add(self)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
