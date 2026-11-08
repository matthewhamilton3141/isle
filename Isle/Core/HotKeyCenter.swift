//
//  HotKeyCenter.swift
//
//  Holds exactly the global shortcuts it's told to, through Carbon's
//  `RegisterEventHotKey` — which needs no permission at all, unlike a global
//  key-down monitor (Input Monitoring) or an event tap (Accessibility). The
//  key is taken from every other app while it's held, and given back the
//  moment it isn't, which is why the pending-only shortcuts can be easy keys.
//
//  Small and testable: the Carbon calls sit behind `HotKeyRegistrar`, and the
//  center only diffs what it's told to hold against what it holds. The tests
//  give it a recording fake, so they never take a key from the session
//  they run in.
//

import Carbon.HIToolbox
import Combine
import Foundation

/// The one place Carbon is called. `onPress` gets the id a key was
/// registered under.
@MainActor
protocol HotKeyRegistrar: AnyObject {
    var onPress: ((UInt32) -> Void)? { get set }
    /// `noErr`, or why not — `eventHotKeyExistsErr` when another app holds
    /// the combo exclusively.
    func register(_ combo: KeyCombo, id: UInt32) -> OSStatus
    func unregister(id: UInt32)
}

@MainActor
final class HotKeyCenter: ObservableObject {
    /// The app's. Made on first use, so nothing that never asks for it —
    /// the tests, the render harness — ever installs a handler.
    static let shared = HotKeyCenter(registrar: CarbonHotKeyRegistrar())

    /// What each action's registration last came to, while it's wanted:
    /// held, or refused with a status. Kept after the action is let go, so
    /// Settings can say a pending-only key was refused the last time a
    /// request waited; cleared when its combo changes or it's held again.
    enum Status: Equatable {
        case held
        case refused(OSStatus)
    }

    @Published private(set) var status: [ShortcutAction: Status] = [:]

    /// What's held now, by action. Refused ones aren't here.
    private(set) var held: [ShortcutAction: KeyCombo] = [:]

    /// What was last asked for, refused or not — so a refusal isn't retried
    /// on every apply, only when the action is let go and wanted again, or
    /// wanted on other keys.
    private var attempted: [ShortcutAction: KeyCombo] = [:]

    /// The last set asked for, kept while suspended.
    private var wanted: [ShortcutAction: KeyCombo] = [:]

    /// Everything let go while true — the Settings recorder sets it, so the
    /// combo being typed reaches the recorder instead of firing. Published
    /// so the island's key hints go faint with the keys (`NotchShortcuts`).
    @Published var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            reconcile()
        }
    }

    /// A held shortcut was pressed.
    var onAction: ((ShortcutAction) -> Void)?

    private let registrar: HotKeyRegistrar

    init(registrar: HotKeyRegistrar) {
        self.registrar = registrar
        registrar.onPress = { [weak self] id in
            guard let self, let action = ShortcutAction(hotKeyID: id), self.held[action] != nil else { return }
            self.onAction?(action)
        }
    }

    /// Hold exactly `wanted`: let go of what isn't in it (or is on other
    /// keys now), then take what's new. Lets go first, so a combo moving
    /// from one action to another is free when it's taken again.
    func apply(_ wanted: [ShortcutAction: KeyCombo]) {
        self.wanted = wanted
        reconcile()
    }

    private func reconcile() {
        let target = isSuspended ? [:] : wanted
        for (action, combo) in attempted where target[action] != combo {
            if held[action] != nil {
                registrar.unregister(id: action.hotKeyID)
                held[action] = nil
            }
            attempted[action] = nil
            // A combo that changed starts with a clean slate.
            if let now = wanted[action], now != combo, case .refused = status[action] { status[action] = nil }
        }
        for (action, combo) in target where attempted[action] == nil {
            attempted[action] = combo
            let result = registrar.register(combo, id: action.hotKeyID)
            if result == noErr {
                held[action] = combo
                if status[action] != .held { status[action] = .held }
            } else {
                status[action] = .refused(result)
            }
        }
        // Held only while held: what's let go keeps a refusal, not a "held".
        for (action, value) in status where value == .held && held[action] == nil {
            status[action] = nil
        }
    }

    /// Whether `combo` can be taken now, asked by taking it and letting go
    /// straight away, under an id no action uses. For the recorder: says at
    /// once that another app has a pending-only key, rather than the next
    /// time a request waits.
    func probe(_ combo: KeyCombo) -> OSStatus {
        let id = UInt32(ShortcutAction.allCases.count + 1)
        let result = registrar.register(combo, id: id)
        if result == noErr { registrar.unregister(id: id) }
        return result
    }

    /// Forget what Settings shows about an action — its combo just changed.
    func clearStatus(_ action: ShortcutAction) {
        if case .refused = status[action] { status[action] = nil }
    }

    /// Plain words for a refusal.
    static func describe(_ status: OSStatus) -> String {
        switch Int(status) {
        case eventHotKeyExistsErr: return "Another app already has this shortcut."
        case eventHotKeyInvalidErr: return "macOS won’t take this key as a shortcut."
        default: return "macOS refused this shortcut (error \(status))."
        }
    }
}

// MARK: - Carbon

/// The real thing: one application-wide handler for hot-key presses, and a
/// registration per id. Registered as exclusive, so an app that took the
/// same combo exclusively first is reported rather than silently shared.
@MainActor
final class CarbonHotKeyRegistrar: HotKeyRegistrar {
    var onPress: ((UInt32) -> Void)?

    /// "ISLE".
    private static let signature: OSType = 0x4953_4C45

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?

    func register(_ combo: KeyCombo, id: UInt32) -> OSStatus {
        installHandlerIfNeeded()
        if let old = refs.removeValue(forKey: id) { UnregisterEventHotKey(old) }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        if status == noErr, let ref { refs[id] = ref }
        return status
    }

    func unregister(id: UInt32) {
        guard let ref = refs.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(ref)
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard status == noErr, hotKey.signature == CarbonHotKeyRegistrar.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let registrar = Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
            let id = hotKey.id
            // Carbon calls back on the main thread; hop explicitly all the
            // same, so the press lands outside Carbon's dispatch.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { registrar.onPress?(id) }
            }
            return noErr
        }, 1, &spec, me, &handler)
    }
}
