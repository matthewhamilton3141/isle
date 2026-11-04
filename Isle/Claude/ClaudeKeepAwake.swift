//
//  ClaudeKeepAwake.swift
//
//  Keeps the Mac from idling to sleep while a Claude Code turn is in flight.
//  A long agentic turn is exactly when nobody touches the keyboard, so the
//  idle timer runs out mid-turn, the system sleeps, and the session stalls
//  until someone comes back to wake it.
//
//  One power assertion, owned here, taken and released by a single boolean.
//  Deciding *whether* anything is working is not this type's job — the view
//  model already concludes that per session (see
//  `NotchViewModel.updateKeepAwake`), and this only carries the answer to
//  IOKit. Keeping the two apart is what lets the assertion follow Isle's own
//  state exactly instead of growing a second opinion about it.
//
//  Why `PreventUserIdleSystemSleep` and nothing stronger:
//
//    * It's the one that matters. The turn needs the CPU, the network and the
//      CLI process to keep running; it does not need the screen. The display
//      still dims, sleeps and locks on its usual schedule — what `caffeinate
//      -i` does, not `caffeinate -d`.
//    * It holds on battery. `PreventSystemSleep` is honoured only on AC power,
//      which would quietly make the toggle a no-op on the laptop it's for.
//    * It doesn't fight the user. Closing the lid, choosing Sleep, or the
//      battery running low still sleep the Mac; this only stops the idle
//      timer from doing it on its own.
//
//  Idempotent by construction: there is at most one assertion id, a second
//  take while holding is a no-op, and a release with nothing held is too. The
//  kernel also drops every assertion a process holds when it exits, so even a
//  crash can't leave the Mac pinned awake.
//
//  `pmset -g assertions` lists it by `assertionName` while it's held.
//

import Foundation
import IOKit.pwr_mgt

@MainActor
final class ClaudeKeepAwake {
    /// What `pmset -g assertions` and Activity Monitor show for the hold.
    static let assertionName = "Isle: Claude Code is working"

    /// The live assertion, or nil when nothing is held. The only state there
    /// is — `isHeld` reads straight off it, so nothing can claim the Mac is
    /// being kept awake without an assertion actually behind it.
    private var assertionID: IOPMAssertionID?

    var isHeld: Bool { assertionID != nil }

    /// Takes or releases the assertion to match `held`. Safe to call on every
    /// re-selection: a call that agrees with the current state does nothing.
    func setHeld(_ held: Bool) {
        held ? take() : release()
    }

    func release() {
        guard let id = assertionID else { return }
        assertionID = nil
        IOPMAssertionRelease(id)
    }

    private func take() {
        guard assertionID == nil else { return }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.assertionName as CFString,
            &id
        )
        // A refused assertion stays unheld rather than being recorded — so
        // `isHeld` stays honest, and the next re-selection simply tries again.
        guard result == kIOReturnSuccess else { return }
        assertionID = id
    }

    deinit {
        if let assertionID { IOPMAssertionRelease(assertionID) }
    }
}
