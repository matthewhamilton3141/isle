//
//  NotchViewModel+LiveStrip.swift
//
//  The live strip, wired to the island: what the rules in `LiveStrip` are
//  fed, the hold an open settles on, the panel height the strip adds, and
//  the agenda chip's minute clock. The views read `strip(on:room:)`; the
//  panel's height reads `faceContentHeight(of:room:)`, through the same
//  call, so the two can't disagree.
//

import Foundation

extension NotchViewModel {
    // MARK: - Inputs

    /// The moment, as `LiveStrip` reads it.
    var stripInputs: LiveStrip.Inputs {
        let now = stripNow
        let call = AgendaLayout.joinable(agendaItems, at: now, lead: agendaJoinLead)?.0.id
        return LiveStrip.Inputs(
            tabs: availableTabs,
            claudeSession: claudeState != .disconnected || !sessionList.isEmpty,
            claudeAsking: pendingRequest != nil,
            hasTrack: media.hasTrack,
            timerActive: pomodoro.isActive,
            events: agendaItems.map {
                LiveStrip.Event(id: $0.id, start: $0.date, end: $0.end, isAllDay: $0.isAllDay,
                                isEvent: $0.kind == .event, joinable: $0.id == call)
            },
            shelfCount: shelf.items.count,
            now: now
        )
    }

    /// The strip's clock: on the minute while a panel is open (so "in 12
    /// min" counts down and a call's Join comes forward), the wall clock
    /// otherwise.
    var stripNow: Date {
        stripOpenPanels > 0 ? stripMinute : Date()
    }

    // MARK: - The hold

    /// The primary face and whether the strip is up, as this open settled
    /// them (`LiveStrip.hold`). While closed, the moment's own.
    var stripSettled: LiveStrip.Hold {
        let inputs = stripInputs
        let primary = liveStripEnabled ? LiveStrip.primary(inputs) : nil
        let live = LiveStrip.Hold(
            primary: primary,
            shown: primary.map { !LiveStrip.content(on: $0, inputs).isEmpty } ?? false,
            takeover: inputs.claudeAsking,
            enabled: liveStripEnabled
        )
        guard stripOpenPanels > 0 else { return live }
        let held = LiveStrip.hold(previous: stripHold, live: live)
        // Not published: a new hold only ever settles on what's on screen
        // (the open's first frame, a takeover's, the setting's).
        if held != stripHold { stripHold = held }
        return held
    }

    /// The face the strip is under, or nil with the strip off.
    var stripPrimaryFace: IsleTab? {
        liveStripEnabled ? stripSettled.primary : nil
    }

    /// Where the island opens with the strip on: its primary face, unless
    /// the user has gone somewhere else during this open. Nil: as without
    /// the strip.
    var stripPrimaryPlace: NotchPlace? {
        guard liveStripEnabled, !leftPrimary, let face = stripSettled.primary,
              availableTabs.contains(face) else { return nil }
        return .face(face)
    }

    // MARK: - What's drawn

    /// The strip under `face` in a panel whose content can be `room` tall,
    /// or nil for none. Only the primary face has one, and a question has
    /// one only if its options still fit without scrolling above it.
    func strip(on face: IsleTab, room: CGFloat) -> LiveStrip.Content? {
        guard liveStripEnabled else { return nil }
        let settled = stripSettled
        guard settled.shown, face == settled.primary else { return nil }
        if face == .claude, !sessionListShown, let request = pendingRequest, request.kind == .question {
            let fits = request.questions.allSatisfy {
                !ClaudePanelLayout.fit($0, descriptions: optionDescriptions, trailingClearance: 0,
                                       room: room - LiveStrip.height).scrolls
            }
            guard fits else { return nil }
        }
        return LiveStrip.content(on: face, stripInputs)
    }

    /// The content height `face` wants, the strip under it included: the
    /// face is fitted to what the strip leaves, and a face that wants no
    /// more than the standard panel keeps the standard content above it.
    func faceContentHeight(of face: IsleTab, room: CGFloat) -> CGFloat? {
        guard strip(on: face, room: room) != nil else { return faceOwnContentHeight(of: face, room: room) }
        let standard = NotchMetrics.expandedSize.height - (NotchMetrics.panelMaxHeight - room)
        let own = faceOwnContentHeight(of: face, room: room - LiveStrip.height) ?? standard
        return min(room, own + LiveStrip.height)
    }

    // MARK: - Open and close

    /// A panel opened (its content appeared). The first settles the hold
    /// and starts the minute clock.
    func stripPanelOpened() {
        stripOpenPanels += 1
        guard stripOpenPanels == 1 else { return }
        stripHold = nil
        stripMinute = Date()
        _ = stripSettled
        startStripTicker()
    }

    /// A panel closed. The last lets go of the hold and of anywhere the user
    /// went, so the next open is the primary face again.
    func stripPanelClosed() {
        stripOpenPanels = max(0, stripOpenPanels - 1)
        guard stripOpenPanels == 0 else { return }
        stripHold = nil
        leftPrimary = false
        stripTicker?.invalidate()
        stripTicker = nil
    }

    /// On the minute, while open and while there's an agenda to count down.
    /// A plain timer rather than a TimelineView: one publish a minute, and
    /// nothing at all while the island is closed.
    private func startStripTicker() {
        stripTicker?.invalidate()
        stripTicker = nil
        guard liveStripEnabled, availableTabs.contains(.agenda) else { return }
        let now = Date()
        let next = Calendar.current.nextDate(after: now, matching: DateComponents(second: 0),
                                             matchingPolicy: .nextTime) ?? now.addingTimeInterval(60)
        let timer = Timer(fire: next, interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stripMinute = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
        stripTicker = timer
    }
}
