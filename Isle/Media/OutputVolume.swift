//
//  OutputVolume.swift
//
//  The system default output's volume and mute, for the slider at the head
//  of the output list.
//
//  What the slider shows is what the device reports and nothing else. The
//  level is the HAL's virtual main volume — the control the volume keys and
//  Control Center move, which keeps a device's balance as it goes — falling
//  back to the device's own scalar volume where it has no virtual main. A
//  device with neither (some HDMI and USB outputs, which leave volume to
//  whatever is on the other end) has no `state` at all and the slider isn't
//  drawn: Isle doesn't offer a control it can't back up. One that reports a
//  level but won't let it be set shows that level, greyed.
//
//  It follows the default output as `OutputDevices` reads it, and listens to
//  the HAL only while the list is open, so the volume keys and Control
//  Center move the slider while it's on screen and cost nothing otherwise.
//  All HAL work runs on `OutputDevices.queue`, so a volume write is ordered
//  against a device switch rather than racing it.
//

import Foundation
import CoreAudio
import AudioToolbox
import Combine

@MainActor
final class OutputVolume: ObservableObject {
    struct State: Equatable {
        /// 0...1, as the device reports it.
        var level: Float
        var canSetLevel: Bool
        /// Nil when the device has no mute control.
        var isMuted: Bool?
        var canMute: Bool
    }

    /// The default output's volume, or nil when there's nothing to show: no
    /// default device, a device with no volume control, or nobody looking.
    @Published private(set) var state: State?

    private var deviceID: AudioObjectID?
    private var controls: Controls?
    private var viewers = 0

    /// Bumped whenever the device or the viewers change, so a read or a
    /// write that lands after either stays quiet.
    private var generation = 0

    private var listener: AudioObjectPropertyListenerBlock?
    private var listenedAddresses: [AudioObjectPropertyAddress] = []
    private var listenedDevice: AudioObjectID?

    // MARK: - Following the default

    /// Points the control at the current default output. Called by
    /// `OutputDevices` with every read of the default, so it does nothing
    /// unless the device actually changed.
    func follow(_ id: AudioObjectID?) {
        guard id != deviceID else { return }
        deviceID = id
        rebind()
    }

    func attach() {
        viewers += 1
        guard viewers == 1 else { return }
        rebind()
    }

    func detach() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        rebind()
    }

    /// Drops whatever was bound and, if someone is looking at a device,
    /// binds to it afresh: which controls it has, their values, and a
    /// listener on each.
    private func rebind() {
        generation += 1
        stopListening()
        controls = nil
        pendingLevel = nil
        pendingUnmute = false
        isWriting = false
        if state != nil { state = nil }

        guard viewers > 0, let device = deviceID else { return }
        let generation = generation
        OutputDevices.queue.async { [weak self] in
            let controls = Controls(device)
            let state = controls.flatMap { Self.read($0) }
            let addresses = controls.map { $0.levelAddresses + ($0.mute.map { [$0] } ?? []) } ?? []
            Task { @MainActor in
                guard let self, self.generation == generation, let controls else { return }
                self.controls = controls
                self.startListening(controls, addresses)
                self.publish(state)
            }
        }
    }

    // MARK: - Writing

    /// The level the slider was last dragged to, not yet sent.
    private var pendingLevel: Float?

    /// The device is muted and a drag has asked for it not to be; sent with
    /// the next level.
    private var pendingUnmute = false

    /// A write is on its way. Writes go one at a time, each taking the
    /// latest dragged level when it's sent: a fast drag sends as many levels
    /// as the HAL takes, never a backlog of stale ones that would trail on
    /// after the thumb stopped.
    private var isWriting = false

    /// When the last write went out. Writes are spaced at least
    /// `writeSpacing` apart — still display rate, so the sound follows the
    /// thumb, but not a volume message to a Bluetooth device for every
    /// pointer event.
    private var lastWrite: Date = .distantPast
    private static let writeSpacing: TimeInterval = 1.0 / 30.0

    /// Sets the level, as dragged. Shown at once — the slider is under the
    /// pointer — and written behind it. A muted device is unmuted, as the
    /// volume keys do: raising the volume of something silent is asking to
    /// hear it.
    func setLevel(_ level: Float) {
        guard var state, state.canSetLevel else { return }
        let level = min(max(level, 0), 1)
        state.level = level
        if state.isMuted == true, state.canMute, level > 0 {
            state.isMuted = false
            pendingUnmute = true
        }
        if self.state != state { self.state = state }
        pendingLevel = level
        writeIfIdle()
    }

    func toggleMute() {
        guard var state, state.canMute, let muted = state.isMuted,
              let controls, let mute = controls.mute else { return }
        state.isMuted = !muted
        self.state = state
        pendingUnmute = false
        let generation = generation
        OutputDevices.queue.async { [weak self] in
            Self.setMute(!muted, controls.device, mute)
            Task { @MainActor in self?.reread(generation) }
        }
    }

    private func writeIfIdle() {
        guard !isWriting, pendingLevel != nil, controls != nil else { return }
        isWriting = true
        let wait = Self.writeSpacing - Date().timeIntervalSince(lastWrite)
        guard wait > 0 else {
            sendPending()
            return
        }
        let generation = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, self.generation == generation else { return }
            self.sendPending()
        }
    }

    /// Sends the latest dragged level — taken now, not when the write was
    /// asked for, so wherever the drag got to in the meantime is what goes.
    private func sendPending() {
        guard let level = pendingLevel, let controls else {
            isWriting = false
            return
        }
        pendingLevel = nil
        let unmute = pendingUnmute
        pendingUnmute = false
        lastWrite = Date()
        let generation = generation
        OutputDevices.queue.async { [weak self] in
            Self.setLevel(level, controls)
            if unmute, let mute = controls.mute {
                Self.setMute(false, controls.device, mute)
            }
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.isWriting = false
                if self.pendingLevel != nil {
                    self.writeIfIdle()
                } else {
                    self.reread(generation)
                }
            }
        }
    }

    // MARK: - Listening

    /// Registered and removed on `OutputDevices.queue`, like every other
    /// HAL call here — an add or a remove is a round trip to the audio
    /// server, and finding the addresses asks the device which controls it
    /// has. Serial, so a remove can't overtake the add it undoes. What was
    /// added stays recorded here on the main actor, next to the generation
    /// that says whether a bind still counts.
    private func startListening(_ controls: Controls, _ addresses: [AudioObjectPropertyAddress]) {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.reread(self.generation)
            }
        }
        let device = controls.device
        self.listener = listener
        listenedAddresses = addresses
        listenedDevice = device
        OutputDevices.queue.async {
            for var address in addresses {
                let status = AudioObjectAddPropertyListenerBlock(
                    device, &address, OutputDevices.queue, listener
                )
                if status != noErr {
                    NSLog("Isle: could not watch the output volume (\(status))")
                }
            }
        }
    }

    private func stopListening() {
        guard let listener, let device = listenedDevice else { return }
        let addresses = listenedAddresses
        self.listener = nil
        listenedAddresses = []
        listenedDevice = nil
        OutputDevices.queue.async {
            for var address in addresses {
                AudioObjectRemovePropertyListenerBlock(device, &address, OutputDevices.queue, listener)
            }
        }
    }

    /// Re-reads the device and publishes what it says — unless a drag is
    /// still being written, when the HAL's answer is a level the thumb has
    /// already left. The last write re-reads when it lands, so the slider
    /// settles on what the device actually took (a Bluetooth device rounds
    /// to its own steps).
    private func reread(_ generation: Int) {
        guard generation == self.generation, let controls, !isWriting, pendingLevel == nil else { return }
        OutputDevices.queue.async { [weak self] in
            let state = Self.read(controls)
            Task { @MainActor in
                guard let self, self.generation == generation,
                      !self.isWriting, self.pendingLevel == nil else { return }
                self.publish(state)
            }
        }
    }

    private func publish(_ state: State?) {
        if self.state != state { self.state = state }
    }
}

// MARK: - HAL

extension OutputVolume {
    /// Which of a device's controls the slider drives, found once per device.
    struct Controls {
        let device: AudioObjectID
        let level: Level
        /// The output mute, when the device has one.
        let mute: AudioObjectPropertyAddress?
        let canSetLevel: Bool
        let canMute: Bool

        enum Level {
            /// The HAL's virtual main volume: one value for the whole
            /// device, kept in balance across its channels.
            case virtualMain
            /// The device's own scalar volume on these elements — the main
            /// element, or each of the stereo pair — all set alike.
            case scalar([AudioObjectPropertyElement])
        }

        /// Every address whose change means the level may have moved, for
        /// the listeners. The virtual main is watched along with the scalar
        /// volumes under it, so the slider follows whichever the HAL
        /// reports a change on.
        var levelAddresses: [AudioObjectPropertyAddress] {
            var addresses: [AudioObjectPropertyAddress] = []
            if case .virtualMain = level {
                addresses.append(OutputVolume.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume))
            }
            for element in OutputVolume.scalarElements(device) {
                addresses.append(OutputVolume.address(kAudioDevicePropertyVolumeScalar, element))
            }
            return addresses
        }

        /// Nil when the device has no volume control Isle can read.
        init?(_ device: AudioObjectID) {
            self.device = device
            var virtualMain = OutputVolume.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            if AudioObjectHasProperty(device, &virtualMain) {
                level = .virtualMain
                canSetLevel = OutputVolume.isSettable(device, virtualMain)
            } else {
                let elements = OutputVolume.scalarElements(device)
                guard !elements.isEmpty else { return nil }
                level = .scalar(elements)
                canSetLevel = elements.allSatisfy {
                    OutputVolume.isSettable(device, OutputVolume.address(kAudioDevicePropertyVolumeScalar, $0))
                }
            }
            var muteAddress = OutputVolume.address(kAudioDevicePropertyMute)
            if AudioObjectHasProperty(device, &muteAddress) {
                mute = muteAddress
                canMute = OutputVolume.isSettable(device, muteAddress)
            } else {
                mute = nil
                canMute = false
            }
        }
    }

    nonisolated static func read(_ controls: Controls) -> State? {
        let level: Float?
        switch controls.level {
        case .virtualMain:
            level = float32(controls.device, address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume))
        case .scalar(let elements):
            // The louder channel, as Sound settings shows an unbalanced pair.
            level = elements
                .compactMap { float32(controls.device, address(kAudioDevicePropertyVolumeScalar, $0)) }
                .max()
        }
        guard let level else { return nil }
        let muted = controls.mute.flatMap { uint32(controls.device, $0) }.map { $0 != 0 }
        return State(
            level: min(max(level, 0), 1),
            canSetLevel: controls.canSetLevel,
            isMuted: muted,
            canMute: controls.canMute && muted != nil
        )
    }

    nonisolated static func setLevel(_ level: Float, _ controls: Controls) {
        switch controls.level {
        case .virtualMain:
            setFloat32(level, controls.device, address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume))
        case .scalar(let elements):
            for element in elements {
                setFloat32(level, controls.device, address(kAudioDevicePropertyVolumeScalar, element))
            }
        }
    }

    nonisolated static func setMute(_ muted: Bool, _ device: AudioObjectID, _ address: AudioObjectPropertyAddress) {
        var address = address
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
        )
        if status != noErr { NSLog("Isle: could not set output mute (\(status))") }
    }

    /// The elements carrying a scalar volume: the main element if it has
    /// one, otherwise the device's preferred stereo pair, as far as those
    /// have one.
    nonisolated static func scalarElements(_ device: AudioObjectID) -> [AudioObjectPropertyElement] {
        var main = address(kAudioDevicePropertyVolumeScalar)
        if AudioObjectHasProperty(device, &main) { return [kAudioObjectPropertyElementMain] }

        var stereoAddress = address(kAudioDevicePropertyPreferredChannelsForStereo)
        var stereo: [UInt32] = [0, 0]
        var size = UInt32(MemoryLayout<UInt32>.size * 2)
        guard AudioObjectGetPropertyData(device, &stereoAddress, 0, nil, &size, &stereo) == noErr else {
            return []
        }
        return Array(Set(stereo)).sorted().filter {
            var channel = address(kAudioDevicePropertyVolumeScalar, $0)
            return AudioObjectHasProperty(device, &channel)
        }
    }

    nonisolated static func address(
        _ selector: AudioObjectPropertySelector,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
    }

    private nonisolated static func isSettable(_ device: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    private nonisolated static func float32(_ device: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Float? {
        var address = address
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private nonisolated static func uint32(_ device: AudioObjectID, _ address: AudioObjectPropertyAddress) -> UInt32? {
        var address = address
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private nonisolated static func setFloat32(_ value: Float, _ device: AudioObjectID, _ address: AudioObjectPropertyAddress) {
        var address = address
        var value = Float32(value)
        let status = AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value
        )
        if status != noErr { NSLog("Isle: could not set output volume (\(status))") }
    }
}
