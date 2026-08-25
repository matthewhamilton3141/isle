//
//  SystemAudioLevels.swift
//
//  Real audio-reactive levels for the notch waveform.
//
//  Taps the system's default output device with Core Audio's process-tap
//  API (macOS 14.4+), runs an FFT over the captured samples, and reduces
//  the spectrum to a handful of log-spaced bands.
//
//  A global tap is used rather than a per-process one so the waveform
//  follows whatever is actually audible — the same reason the now-playing
//  feed is source-agnostic. This does mean a system alert sound will nudge
//  the bars, which is correct behaviour for a level meter.
//
//  Everything here fails soft. If the OS is too old, the user declines the
//  audio-capture prompt, or the device can't be tapped, `levels` simply
//  stays empty and EqualizerView falls back to its procedural pattern.
//

import Foundation
import AudioToolbox
import CoreAudio
import Accelerate
import Combine

@MainActor
final class SystemAudioLevels: ObservableObject {
    /// Per-band magnitudes, 0...1. Empty when capture isn't running.
    @Published private(set) var levels: [Double] = []

    /// Set when capture couldn't start, for the settings pane to surface.
    @Published private(set) var failureReason: String?

    private let bandCount: Int

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?

    /// All DSP lives in here, off the main actor entirely.
    ///
    /// This class is `@MainActor` because it's an ObservableObject, but the
    /// audio callback arrives on a realtime Core Audio thread. Hopping to the
    /// main actor from there is not an option — `assumeIsolated` traps, and
    /// an async hop would both miss the deadline and reorder buffers. So the
    /// analysis is deliberately isolated into a plain, lock-guarded object
    /// that the audio thread may touch directly.
    private let analyzer: AudioAnalyzer

    private var displayTimer: Timer?

    #if DEBUG
    private var diagnosticTimer: Timer?
    #endif

    init(bandCount: Int = 6) {
        self.bandCount = bandCount
        self.analyzer = AudioAnalyzer(bandCount: bandCount)
    }

    // MARK: - Lifecycle

    func start() {
        guard #available(macOS 14.4, *) else {
            failureReason = "System audio capture requires macOS 14.4 or later."
            return
        }
        guard aggregateID == kAudioObjectUnknown else { return }

        do {
            try startCapture()
            startPublishing()
            failureReason = nil
        } catch {
            failureReason = "\(error.localizedDescription)"
            NSLog("Isle: audio capture unavailable — \(error.localizedDescription)")
            stop()
        }
    }

    func stop() {
        displayTimer?.invalidate()
        displayTimer = nil

        #if DEBUG
        diagnosticTimer?.invalidate()
        diagnosticTimer = nil
        #endif

        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        ioProcID = nil

        if tapID != kAudioObjectUnknown {
            // Guarded rather than hoisted to the whole method: the aggregate
            // device teardown above has no version requirement and must run
            // regardless, or we'd leak a device on older systems.
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(tapID)
            }
            tapID = kAudioObjectUnknown
        }

        levels = []
    }

    // MARK: - Capture setup

    @available(macOS 14.4, *)
    private func startCapture() throws {
        let outputUID = try defaultOutputDeviceUID()

        // Empty exclusion list => tap everything the device is playing.
        let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tap)
        guard tapStatus == noErr else {
            throw AudioLevelError.tapCreationFailed(tapStatus)
        }
        tapID = tap

        // The tap can only be read through an aggregate device that includes
        // both it and the real output device.
        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Isle Level Meter",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            // Private keeps it out of the user's Sound settings — this is an
            // implementation detail, not a device they chose to create.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                ]
            ],
        ]

        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            description as CFDictionary, &aggregate
        )
        guard aggregateStatus == noErr else {
            throw AudioLevelError.aggregateCreationFailed(aggregateStatus)
        }
        aggregateID = aggregate

        var procID: AudioDeviceIOProcID?
        // Capture the analyzer, not self: self is main-actor isolated and
        // must not be touched from the realtime thread at all.
        let analyzer = self.analyzer
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregate,
            nil
        ) { _, inputData, _, _, _ in
            // Realtime audio thread: no allocation, no actor hops, no
            // unbounded waits.
            analyzer.process(inputData)
        }
        guard procStatus == noErr, let procID else {
            throw AudioLevelError.ioProcFailed(procStatus)
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregate, procID)
        guard startStatus == noErr else {
            throw AudioLevelError.startFailed(startStatus)
        }
    }

    private func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw AudioLevelError.noOutputDevice
        }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        let uidStatus = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &uidSize, pointer)
        }
        guard uidStatus == noErr else {
            throw AudioLevelError.noOutputDevice
        }
        return uid as String
    }

    // MARK: - Publishing

    /// Republish at display rate rather than per audio callback — the
    /// callback fires far more often than the screen refreshes, and driving
    /// SwiftUI from it would be pure wasted work.
    private func startPublishing() {
        let analyzer = self.analyzer

        #if DEBUG
        diagnosticTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let (calls, peak) = analyzer.drainDiagnostics()
                let levels = analyzer.snapshot()
                    .map { String(format: "%.2f", $0) }
                    .joined(separator: " ")
                let line = "calls=\(calls) peak=\(String(format: "%.5f", peak)) levels=[\(levels)]\n"
                // A file rather than NSLog: this app is LSUIElement and its
                // NSLog output does not reach the unified log where it can be
                // read back, which makes NSLog useless for diagnosing it.
                if let data = line.data(using: .utf8) {
                    let url = URL(fileURLWithPath: "/tmp/isle-audio.log")
                    if let handle = try? FileHandle(forWritingTo: url) {
                        handle.seekToEndOfFile()
                        try? handle.write(contentsOf: data)
                        try? handle.close()
                    } else {
                        try? data.write(to: url)
                    }
                }
            }
        }
        #endif

        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            // Timer callbacks genuinely are delivered on the main run loop, so
            // assuming main-actor isolation here is sound — unlike in the audio
            // callback, where the same assumption traps.
            MainActor.assumeIsolated {
                self?.levels = analyzer.snapshot()
            }
        }
    }
}

// MARK: - Analysis

/// Windowed FFT reduced to log-spaced bands.
///
/// Intentionally *not* actor-isolated. The Core Audio IOProc calls straight
/// into `process` on a realtime thread; the only shared mutable state is the
/// smoothed output, guarded by a lock that is never held across anything
/// slow. Everything else is touched solely from that one audio thread.
private final class AudioAnalyzer: @unchecked Sendable {
    private let bandCount: Int

    /// FFT scratch, sized once. Allocating inside the callback is the classic
    /// way to cause audio dropouts.
    private let fftSize = 1024
    private var fftSetup: FFTSetup?
    private var window: [Float]
    private var realParts: [Float]
    private var imagParts: [Float]
    private var magnitudes: [Float]
    private var sampleBuffer: [Float]

    private let lock = NSLock()
    private var smoothed: [Double]

    /// Diagnostics, guarded by the same lock as `smoothed`.
    private var callCount = 0
    private var peak: Float = 0

    init(bandCount: Int) {
        self.bandCount = bandCount
        self.smoothed = Array(repeating: 0, count: bandCount)

        window = [Float](repeating: 0, count: fftSize)
        realParts = [Float](repeating: 0, count: fftSize / 2)
        imagParts = [Float](repeating: 0, count: fftSize / 2)
        magnitudes = [Float](repeating: 0, count: fftSize / 2)
        sampleBuffer = [Float](repeating: 0, count: fftSize)

        let log2n = vDSP_Length(log2(Float(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    func snapshot() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return smoothed
    }

    /// Callback count and peak sample seen since the last call, then reset.
    ///
    /// Exists to tell apart the two failure modes that look identical from the
    /// UI: the IOProc never firing (tap/aggregate is broken) versus it firing
    /// with silent buffers (permission denied — Core Audio hands over zeroes
    /// rather than returning an error).
    func drainDiagnostics() -> (calls: Int, peak: Float) {
        lock.lock()
        defer {
            callCount = 0
            peak = 0
            lock.unlock()
        }
        return (callCount, peak)
    }

    /// Called on the realtime audio thread.
    func process(_ bufferList: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList)
        )
        guard let first = buffers.first,
              let data = first.mData
        else { return }

        let available = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        guard available > 0 else { return }

        let samples = data.bindMemory(to: Float.self, capacity: available)

        // Peak before any windowing or smoothing, so it reflects exactly what
        // Core Audio handed us.
        var framePeak: Float = 0
        vDSP_maxmgv(samples, 1, &framePeak, vDSP_Length(available))
        lock.lock()
        callCount += 1
        peak = max(peak, framePeak)
        lock.unlock()

        analyse(samples, count: available)
    }

    /// Log-spaced bands rather than linear: linear bands put nearly all of
    /// music's energy in the first bar and leave the rest twitching near zero.
    private func analyse(_ samples: UnsafePointer<Float>, count: Int) {
        guard let fftSetup else { return }

        let n = min(count, fftSize)
        // Zero-fill a short buffer rather than skipping it, so quiet passages
        // still produce output instead of freezing the meter.
        for index in 0..<fftSize {
            sampleBuffer[index] = index < n ? samples[index] : 0
        }

        vDSP_vmul(sampleBuffer, 1, window, 1, &sampleBuffer, 1, vDSP_Length(fftSize))

        let halfSize = fftSize / 2
        let log2n = vDSP_Length(log2(Float(fftSize)))

        realParts.withUnsafeMutableBufferPointer { realPtr in
            imagParts.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(
                    realp: realPtr.baseAddress!,
                    imagp: imagPtr.baseAddress!
                )

                sampleBuffer.withUnsafeBufferPointer { samplePtr in
                    samplePtr.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self, capacity: halfSize
                    ) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }

                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(halfSize))
            }
        }

        // vDSP_fft_zrip returns results scaled by 2N, so raw magnitudes grow
        // with the transform size and have no fixed relationship to the input
        // amplitude. Left unscaled, every band pegged at full height on any
        // audible signal — the meter was saturated rather than responsive.
        var scale = Float(1) / Float(2 * fftSize)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(halfSize))

        var newLevels = [Double](repeating: 0, count: bandCount)
        // Skip bin 0 (DC) — it carries no audible information and would peg
        // the first bar on any signal with an offset.
        let minBin = 1
        let maxBin = halfSize - 1

        for band in 0..<bandCount {
            let lowFraction = Double(band) / Double(bandCount)
            let highFraction = Double(band + 1) / Double(bandCount)
            let low = Int(Double(minBin) * pow(Double(maxBin) / Double(minBin), lowFraction))
            let high = max(low + 1, Int(Double(minBin) * pow(Double(maxBin) / Double(minBin), highFraction)))

            var sum: Float = 0
            for bin in low..<min(high, halfSize) {
                sum += magnitudes[bin]
            }
            let mean = sum / Float(max(1, min(high, halfSize) - low))

            // dB, then map a useful window onto 0...1. Amplitude is
            // perceptually logarithmic, so a linear meter looks dead.
            // Music's energy falls off steeply with frequency, so without a
            // tilt the top bands sit near zero and the waveform looks like it
            // only has three working bars. 4dB per band measured roughly flat
            // across real tracks at bandCount 6 — note this is coupled to the
            // band count, since fewer bands means each spans a wider range and
            // needs more correction.
            let tilt = Double(band) * 4
            let db = 20 * log10(max(mean, 1e-7))
            let normalised = (Double(db) + tilt + 70) / 60
            newLevels[band] = min(max(normalised, 0), 1)
        }

        lock.lock()
        for index in 0..<bandCount {
            let target = newLevels[index]
            // Fast attack, slow release — mirrors a physical VU meter and
            // stops the bars flickering on transients.
            let coefficient = target > smoothed[index] ? 0.55 : 0.12
            smoothed[index] += (target - smoothed[index]) * coefficient
        }
        lock.unlock()
    }
}

enum AudioLevelError: LocalizedError {
    case noOutputDevice
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case startFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noOutputDevice:
            return "No default output device."
        case .tapCreationFailed(let status):
            return "Could not tap system audio (\(status)). Check Privacy & Security › Audio Recording."
        case .aggregateCreationFailed(let status):
            return "Could not create the aggregate device (\(status))."
        case .ioProcFailed(let status):
            return "Could not attach the audio callback (\(status))."
        case .startFailed(let status):
            return "Could not start audio capture (\(status))."
        }
    }
}
