//
//  OutputDevices.swift
//
//  The Mac's audio outputs, which one is the system default, and the means
//  to change it — for the output switcher on the music face.
//
//  Everything shown comes from the HAL and nothing else. The list is what
//  `kAudioHardwarePropertyDevices` holds once filtered (see `isListed`), the
//  current device is whatever `kAudioHardwarePropertyDefaultOutputDevice`
//  reads back, and both are re-read when the HAL says they changed — never
//  polled, and never assumed. A switch made here is a request: the list
//  moves its mark only when the HAL reports the new default, so a switch
//  that fails leaves the device that is actually playing marked, not the
//  one that was asked for.
//
//  A switch made here is the same HAL event as one made in Control Center or
//  Sound settings — the system default changing. The waveform's tap doesn't
//  care which output is current (it reads the player's process, through an
//  aggregate holding no real device; see `SystemAudioLevels`), and nothing
//  here touches it.
//
//  The default output's volume and mute live alongside, in `volume`, for
//  the slider at the head of the device list.
//
//  Separate from the view model for the same reason the audio level source
//  is: a device coming or going redraws the switcher and nothing else. And
//  it only listens while someone is looking — the music face attaches on
//  appear and detaches on disappear, so a collapsed island holds no HAL
//  listeners.
//

import Foundation
import CoreAudio
import Combine

/// One audio output, as Core Audio describes it.
struct OutputDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: Transport
    /// The built-in output is routed to the headphone jack. Only meaningful
    /// for built-in devices; on Apple silicon the jack is usually a device of
    /// its own instead, which reads true here too.
    let isHeadphoneJack: Bool
    /// What a Bluetooth device reports itself as, from its model UID (see
    /// `DeviceSymbol.bluetoothIDs`). Nil for every other transport, and for
    /// a Bluetooth device whose model UID isn't in that form.
    var vendorID: Int? = nil
    var productID: Int? = nil

    enum Transport: Equatable {
        case builtIn, bluetooth, airPlay, usb, display, thunderbolt, aggregate, virtual, other

        init(_ code: UInt32) {
            switch code {
            case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
            case kAudioDeviceTransportTypeAirPlay: self = .airPlay
            case kAudioDeviceTransportTypeUSB: self = .usb
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: self = .display
            case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
            case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: self = .aggregate
            case kAudioDeviceTransportTypeVirtual: self = .virtual
            default: self = .other
            }
        }
    }

    /// An SF Symbol for the device, from its transport.
    ///
    /// The transport is the only thing Core Audio says about what kind of
    /// device this is, so that's what picks the glyph. The exception is a
    /// Bluetooth device that names its model — AirPods and Beats, by product
    /// ID, or AirPods by name — which gets that model's own symbol, shared
    /// with the battery toast (see `DeviceSymbol`). Any other pair gets the
    /// Bluetooth headphones glyph. A laptop's own speakers are the laptop.
    @MainActor
    var symbolName: String {
        switch transport {
        case .builtIn:
            return isHeadphoneJack ? "headphones" : DeviceSymbol.builtInSpeakers
        case .bluetooth:
            return DeviceSymbol.accessory(name: name, vendorID: vendorID, productID: productID)
                ?? "headphones"
        case .airPlay:
            return "airplayaudio"
        case .usb, .thunderbolt:
            return "cable.connector"
        case .display:
            return "display"
        case .aggregate, .virtual, .other:
            return "hifispeaker"
        }
    }
}

@MainActor
final class OutputDevices: ObservableObject {
    /// Outputs a user could pick, in the HAL's order. Empty while nobody is
    /// attached.
    @Published private(set) var devices: [OutputDevice] = []

    /// The system default output, as last read back. Nil while nobody is
    /// attached, or when the HAL reports none.
    @Published private(set) var currentID: AudioObjectID?

    var current: OutputDevice? {
        devices.first { $0.id == currentID }
    }

    /// The current default output's volume and mute. Follows `currentID`;
    /// listens to the HAL only while the device list is open.
    let volume = OutputVolume()

    /// HAL reads and writes happen here, off the main thread: a default
    /// switch to a Bluetooth device can block while it wakes, and a
    /// listener's re-read is no business of the main run loop. Serial so a
    /// re-read can't overtake the switch that prompted it — and shared with
    /// `OutputVolume`, so a volume write can't race a switch either.
    nonisolated static let queue = DispatchQueue(
        label: "com.isle.output-devices", qos: .userInitiated
    )

    /// The re-read waiting to run, if one is. A switch arrives as a burst of
    /// notifications — the device list, the default, the system output, and
    /// again as a Bluetooth device changes profile — and each one used to
    /// queue a full re-read of every device. Now each replaces the last, so
    /// a burst costs one read, taken once it's over.
    private var pendingRefresh: DispatchWorkItem?

    /// How long a re-read waits for the rest of a burst. Short enough that
    /// the tick moves with the switch, not after it.
    private nonisolated static let refreshCoalescing: DispatchTimeInterval = .milliseconds(60)

    private var viewers = 0

    /// Bumped on every detach, so a read that lands after it stays quiet.
    private var generation = 0

    private var listener: AudioObjectPropertyListenerBlock?

    /// The two system properties the list depends on: what devices exist, and
    /// which is the default output.
    private nonisolated static let watched: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultOutputDevice,
    ]

    func attach() {
        viewers += 1
        guard viewers == 1 else { return }
        startListening()
        refresh(coalescing: false)
    }

    func detach() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        stopListening()
        pendingRefresh?.cancel()
        pendingRefresh = nil
        generation += 1
        // Cleared rather than left standing, so the next open starts from
        // what the HAL says then instead of flashing what it said last time.
        devices = []
        currentID = nil
        volume.follow(nil)
    }

    /// Asks the HAL to make `device` the system default output. Nothing is
    /// published from here: the default listener reports the outcome, and on
    /// failure a re-read shows the device that's still the default.
    ///
    /// Only ever called from a tap on the list. Nothing in Isle writes the
    /// default in answer to a notification, so a change can't feed back.
    ///
    /// One thing this can't do is tell macOS the switch was the user's own.
    /// Control Center's switches reach the AirPods' automatic switching as a
    /// "manual route", which holds off its routing the AirPods back for a
    /// while; a HAL write isn't one, and there's no public way to make it
    /// one. With in-ear AirPods connected, macOS may still route them back
    /// the next time something starts playing — its rule, which Isle
    /// doesn't fight (it never writes the default back) and doesn't trigger
    /// itself (the level meter no longer stops or starts on a switch).
    func select(_ device: OutputDevice) {
        guard device.id != currentID else { return }
        let id = device.id
        Self.queue.async { [weak self] in
            let status = Self.setDefaultOutput(id)
            guard status != noErr else { return }
            NSLog("Isle: could not switch output to \(device.name) (\(status))")
            Task { @MainActor in self?.refresh(coalescing: false) }
        }
    }

    // MARK: - Listening

    private func startListening() {
        guard listener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        for selector in Self.watched {
            var address = Self.systemAddress(selector)
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, Self.queue, listener
            )
            if status != noErr {
                NSLog("Isle: could not watch audio outputs (\(status))")
            }
        }
        self.listener = listener
    }

    private func stopListening() {
        guard let listener else { return }
        for selector in Self.watched {
            var address = Self.systemAddress(selector)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, Self.queue, listener
            )
        }
        self.listener = nil
    }

    /// Re-reads the list and the default off the main thread and publishes
    /// both together, so the mark never points at a device the list hasn't
    /// caught up with. Coalesced: see `pendingRefresh`. The first read on
    /// attach isn't delayed, so the list opens on the HAL's answer.
    private func refresh(coalescing: Bool = true) {
        guard viewers > 0 else { return }
        pendingRefresh?.cancel()
        let generation = generation
        let read = DispatchWorkItem { [weak self] in
            let snapshot = Self.snapshot()
            Task { @MainActor in
                guard let self, self.viewers > 0, self.generation == generation else { return }
                if self.devices != snapshot.devices { self.devices = snapshot.devices }
                if self.currentID != snapshot.currentID { self.currentID = snapshot.currentID }
                self.volume.follow(snapshot.currentID)
            }
        }
        pendingRefresh = read
        if coalescing {
            Self.queue.asyncAfter(deadline: .now() + Self.refreshCoalescing, execute: read)
        } else {
            Self.queue.async(execute: read)
        }
    }

    // MARK: - HAL

    nonisolated static func snapshot() -> (devices: [OutputDevice], currentID: AudioObjectID?) {
        let devices = allDeviceIDs().compactMap(describe).filter { isListed($0.facts) }
        return (devices.map(\.device), defaultOutputID())
    }

    /// What `isListed` decides on, kept apart from the device itself so the
    /// harness can print why something was left out.
    struct Facts {
        let outputChannels: Int
        let canBeDefault: Bool
        let isHidden: Bool
        let isPrivateAggregate: Bool
    }

    /// Whether a device belongs in the switcher.
    ///
    /// The HAL's own word decides, not a guess from names:
    /// - It must have output channels — an input-only microphone is a
    ///   device too.
    /// - It must be allowed to be the default output
    ///   (`kAudioDevicePropertyDeviceCanBeDefaultDevice`). This is the flag
    ///   Sound settings honours, and drivers set it false on outputs that
    ///   aren't for playing to directly.
    /// - It must not be hidden (`kAudioDevicePropertyIsHidden`).
    /// - It must not be a private aggregate. Private aggregates are visible
    ///   only to the process that made them, so the only ones Isle can see
    ///   are its own — the waveform's "Isle Level Meter" — which is plumbing,
    ///   not an output. Public aggregates (a Multi-Output Device made in
    ///   Audio MIDI Setup) were made by the user to be chosen, and stay.
    ///
    /// Virtual devices stay too. Some are a deliberate choice — a loopback
    /// driver for recording — and there's no flag that tells those apart
    /// from a meeting app's shim, so Isle lists what Sound settings lists
    /// rather than second-guess it by name.
    nonisolated static func isListed(_ facts: Facts) -> Bool {
        facts.outputChannels > 0 && facts.canBeDefault && !facts.isHidden && !facts.isPrivateAggregate
    }

    nonisolated static func allDeviceIDs() -> [AudioObjectID] {
        var address = systemAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    nonisolated static func defaultOutputID() -> AudioObjectID? {
        var address = systemAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    private nonisolated static func setDefaultOutput(_ id: AudioObjectID) -> OSStatus {
        var address = systemAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var id = id
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &id
        )
    }

    /// The device and the facts about it, or nil if it can't even be named —
    /// a device that has gone away between the list read and this one.
    nonisolated static func describe(_ id: AudioObjectID) -> (device: OutputDevice, facts: Facts)? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID),
              let name = string(id, kAudioObjectPropertyName)
        else { return nil }

        let transport = OutputDevice.Transport(
            uint32(id, kAudioDevicePropertyTransportType) ?? 0
        )
        let dataSource = uint32(id, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
        let ids = transport == .bluetooth
            ? DeviceSymbol.bluetoothIDs(modelUID: string(id, kAudioDevicePropertyModelUID))
            : nil
        let device = OutputDevice(
            id: id,
            uid: uid,
            name: name,
            transport: transport,
            isHeadphoneJack: transport == .builtIn && dataSource == headphonesDataSource,
            vendorID: ids?.vendorID,
            productID: ids?.productID
        )
        let facts = Facts(
            outputChannels: outputChannelCount(id),
            canBeDefault: uint32(id, kAudioDevicePropertyDeviceCanBeDefaultDevice,
                                 scope: kAudioObjectPropertyScopeOutput) == 1,
            isHidden: uint32(id, kAudioDevicePropertyIsHidden) == 1,
            isPrivateAggregate: transport == .aggregate && isPrivateAggregate(id)
        )
        return (device, facts)
    }

    /// 'hdpn', the built-in output's headphone-jack data source.
    private nonisolated static let headphonesDataSource: UInt32 = 0x6864_706E

    private nonisolated static func outputChannelCount(_ id: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private nonisolated static func isPrivateAggregate(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var composition: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &composition) == noErr,
              let dictionary = composition?.takeRetainedValue() as? [String: Any]
        else { return false }
        return (dictionary[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue ?? false
    }

    private nonisolated static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value
        else { return nil }
        return value.takeRetainedValue() as String
    }

    private nonisolated static func uint32(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private nonisolated static func systemAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
