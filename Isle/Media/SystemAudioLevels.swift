//
//  SystemAudioLevels.swift
//
//  Real audio-reactive levels for the notch waveform.
//
//  Taps Spotify's audio with Core Audio's process-tap API (macOS 14.4+),
//  runs an FFT over the captured samples, and reduces the spectrum to a
//  handful of log-spaced bands.
//
//  A process-scoped tap rather than a global one: Isle is Spotify-only, so
//  the waveform must reflect Spotify and nothing else. A global tap made the
//  bars react to any audible sound — a YouTube tab, a system alert — which
//  read as wrong for a Spotify overlay. The tap is bound to Spotify's audio
//  process object, resolved from its PID, and rebuilt when Spotify launches
//  or relaunches (its PID, and therefore the process object, changes).
//
//  Everything here fails soft. If the OS is too old, Spotify isn't running,
//  the user declines the audio-capture prompt, or the device can't be
//  tapped, `levels` simply stays empty and EqualizerView falls back to its
//  procedural pattern.
//

import Foundation
import AppKit
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

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in lifecycleObservers {
            center.removeObserver(observer)
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard #available(macOS 14.4, *) else {
            failureReason = "System audio capture requires macOS 14.4 or later."
            return
        }
        // Rebuild the tap whenever Spotify comes or goes — its PID, and so its
        // audio process object, changes across launches. Registered once.
        observeSpotifyLifecycle()

        guard aggregateID == kAudioObjectUnknown else { return }

        guard let processObject = spotifyProcessObject() else {
            // Spotify isn't running yet. Not an error — the launch observer
            // will start capture once it appears. Leave `levels` empty so the
            // waveform rests as dots rather than reacting to other apps.
            return
        }

        do {
            try startCapture(tapping: processObject)
            startPublishing()
            failureReason = nil
        } catch {
            failureReason = "\(error.localizedDescription)"
            NSLog("Isle: audio capture unavailable — \(error.localizedDescription)")
            stop()
        }
    }

    /// Audio HAL process object for the running Spotify, or nil if Spotify
    /// isn't running (or the translation fails).
    private func spotifyProcessObject() -> AudioObjectID? {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: SpotifyController.bundleID)
            .first else { return nil }

        let pid = app.processIdentifier
        guard pid > 0 else { return nil }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidQualifier = pid
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size), &pidQualifier,
            &size, &processObject
        )
        guard status == noErr, processObject != kAudioObjectUnknown else { return nil }
        return processObject
    }

    // MARK: - Spotify lifecycle

    private var lifecycleObservers: [NSObjectProtocol] = []

    private func observeSpotifyLifecycle() {
        guard lifecycleObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter

        lifecycleObservers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard Self.isSpotify(note) else { return }
            Task { @MainActor in self?.restart() }
        })

        lifecycleObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard Self.isSpotify(note) else { return }
            // Tap is bound to the now-dead process; tear it down so the bars
            // rest rather than freezing on the last frame.
            Task { @MainActor in self?.stop() }
        })
    }

    private nonisolated static func isSpotify(_ note: Notification) -> Bool {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
            .bundleIdentifier == SpotifyController.bundleID
    }

    /// Tear down and bring capture back up against Spotify's current process.
    private func restart() {
        stop()
        start()
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
    private func startCapture(tapping processObject: AudioObjectID) throws {
        let outputUID = try defaultOutputDeviceUID()

        // Scoped to Spotify's process alone, so the meter follows Spotify and
        // ignores every other sound on the system.
        let tapDescription = CATapDescription(monoMixdownOfProcesses: [processObject])
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

        // Band edges are frequencies, not bin indices, so the analyzer needs
        // the real rate. Set before the IOProc starts, so the audio thread
        // never sees it change.
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = Double(0)
        var rateSize = UInt32(MemoryLayout<Double>.size)
        if AudioObjectGetPropertyData(aggregate, &rateAddress, 0, nil, &rateSize, &rate) == noErr,
           rate > 0 {
            analyzer.sampleRate = rate
        }

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
                let (calls, peak, reference, levelPeaks, raw) = analyzer.drainDiagnostics()
                let levels = analyzer.snapshot()
                    .map { String(format: "%.2f", $0) }
                    .joined(separator: " ")
                let peaks = levelPeaks
                    .map { String(format: "%.2f", $0) }
                    .joined(separator: " ")
                let rawText = raw
                    .map { String(format: "%.1f", $0) }
                    .joined(separator: " ")
                let line = "calls=\(calls) peak=\(String(format: "%.5f", peak)) ref=\(String(format: "%.1f", reference)) levels=[\(levels)] max=[\(peaks)] raw=[\(rawText)]\n"
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
                guard let self else { return }
                // Only publish a genuine change. @Published fires on every
                // assignment, equal or not, and each one invalidates the whole
                // notch body — so republishing an unchanged array of zeros
                // kept the UI redrawing at 30Hz through silence and pauses.
                let next = analyzer.snapshot()
                if next != self.levels {
                    self.levels = next
                }
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

    /// Stream sample rate, needed to turn the band edges into real
    /// frequencies. Set once before the IOProc starts, so the audio thread
    /// only ever reads it.
    var sampleRate: Double = 48_000

    /// The spectrum is only followed up to here. Above it, music carries
    /// little but air and cymbal wash, and at a 1024-point FFT everything
    /// over ~10kHz lands in a single enormous band — 331 of 512 bins, whose
    /// mean is so stable it barely moves. Cutting the top off gives six bands
    /// that each cover musically distinct ground instead of five plus a
    /// catch-all.
    private static let topFrequency: Double = 10_000

    /// FFT scratch, sized once. Allocating inside the callback is the classic
    /// way to cause audio dropouts.
    private let fftSize = 1024
    private var fftSetup: FFTSetup?
    private var window: [Float]
    private var realParts: [Float]
    private var imagParts: [Float]
    private var magnitudes: [Float]
    private var sampleBuffer: [Float]

    /// Per-band scratch, sized once for the same reason as the FFT buffers
    /// above — these are written on every callback, ~94 times a second, on the
    /// realtime audio thread. Allocated fresh each time they were three
    /// malloc/free pairs per callback in exactly the place the comment on
    /// `fftSize` warns about. Audio-thread-only, like the rest of the scratch.
    private var bandDb: [Double]
    private var newLevels: [Double]

    /// Slowly-adapting loudness reference, in the same tilted-dB units as the
    /// band levels. Every band is measured *against* this rather than against
    /// a fixed window, which is what makes the display independent of how
    /// loud Spotify itself is playing. Audio-thread-only state, like the FFT
    /// scratch above; the copy under `lock` exists purely for diagnostics.
    private var reference: Double = AudioAnalyzer.referenceStart

    /// How fast the reference chases the signal, per callback (~94/sec).
    ///
    /// Deliberately slow in both directions. The reference has to cancel a
    /// volume change without also cancelling the music's own dynamics — if it
    /// adapted in under a second, a loud chorus would be normalised away as
    /// fast as it arrived and the meter would sit at one height forever.
    /// These work out to roughly a 2s attack and a 5s release, so a volume
    /// change settles over a few seconds while beat-level movement survives.
    private static let referenceAttack = 0.006
    private static let referenceRelease = 0.002

    /// Per-band correction for music's falloff with frequency, in dB.
    ///
    /// Deliberately *under*-corrects. Music falls off about 3.6dB per band
    /// here, and cancelling that exactly is what makes every bar the same
    /// height — a correctly flattened spectrum is precisely a row of matching
    /// lines. 2dB leaves a little over 1.5dB per band of real slope, so the
    /// strip keeps the bass-heavy arc that reads as a spectrum.
    ///
    /// It is coupled to both the band count and the frequency range: fewer
    /// bands, or a wider range, means each band spans more spectrum and falls
    /// off harder. Re-measure if either changes. This was 7 when the bands
    /// were mean-based and ran to 24kHz — against the current bands that
    /// over-lifted the treble so far it inverted the display, bass at 0.33
    /// under treble at 0.65.
    private static let tiltPerBand: Double = 2

    /// Where the reference starts, before any audio has been seen. Roughly the
    /// level of ordinary music, so the first seconds of playback are already
    /// close and settle from there. Starting at the floor instead would peg
    /// every bar at full height until the reference caught up.
    private static let referenceStart: Double = -45

    /// The reference never sinks below this, so genuinely quiet material still
    /// reads as quiet instead of being amplified to full height. Set well
    /// below any real listening level — this is a guard against normalising
    /// a noise floor, not a level control.
    ///
    /// Measured: Spotify at volume 25 settles the reference around -68, so a
    /// floor of -72 would have started clamping — and shrinking the bars —
    /// somewhere below volume 20. -84 leaves room under that.
    ///
    /// Below roughly volume 20 it stops mattering anyway: Spotify's volume
    /// curve falls off a cliff, and at volume 10 its output measures under
    /// -80dBFS — quieter than the residual noise on a paused stream. The
    /// silence gate takes over there and the bars rest as dots, which is the
    /// honest reading of a signal that quiet.
    private static let referenceFloor: Double = -84

    /// Below this RMS the input is treated as true silence: the bars release
    /// to dots and the reference freezes. Without the freeze, the reference
    /// would sink through a pause and the first frame of the next track would
    /// slam every bar to full.
    private static let silenceThreshold: Float = 1e-4

    private let lock = NSLock()
    private var smoothed: [Double]

    /// Diagnostics, guarded by the same lock as `smoothed`.
    private var callCount = 0
    private var peak: Float = 0
    private var referenceReadout: Double = 0
    private var levelPeaks: [Double]
    private var rawReadout: [Double]

    init(bandCount: Int) {
        self.bandCount = bandCount
        self.smoothed = Array(repeating: 0, count: bandCount)
        self.levelPeaks = Array(repeating: 0, count: bandCount)
        self.rawReadout = Array(repeating: 0, count: bandCount)

        bandDb = Array(repeating: 0, count: bandCount)
        newLevels = Array(repeating: 0, count: bandCount)

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
    func drainDiagnostics() -> (calls: Int, peak: Float, reference: Double, levelPeaks: [Double], raw: [Double]) {
        lock.lock()
        let peaks = levelPeaks
        let raw = rawReadout
        defer {
            callCount = 0
            peak = 0
            levelPeaks = Array(repeating: 0, count: bandCount)
            lock.unlock()
        }
        return (callCount, peak, referenceReadout, peaks, raw)
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
        // Broadband RMS, taken from the raw samples before the window scales
        // them. This only drives the silence gate, so it wants the true input
        // amplitude rather than a windowed one.
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(n))
        let isSilent = rms < Self.silenceThreshold

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

        // `rawDb` feeds `rawReadout`, which only `drainDiagnostics` reads and
        // only the DEBUG logging timer calls — so in a release build it was an
        // array allocated on the realtime audio thread ~94 times a second to
        // fill a readout nothing would ever look at. Built only where it's used.
        #if DEBUG
        var rawDb = [Double](repeating: 0, count: bandCount)
        #endif
        // Skip bin 0 (DC) — it carries no audible information and would peg
        // the first bar on any signal with an offset.
        let minBin = 1
        let binWidth = sampleRate / Double(fftSize)
        let maxBin = min(halfSize - 1, max(minBin + 1, Int(Self.topFrequency / binWidth)))

        for band in 0..<bandCount {
            let lowFraction = Double(band) / Double(bandCount)
            let highFraction = Double(band + 1) / Double(bandCount)
            let low = Int(Double(minBin) * pow(Double(maxBin) / Double(minBin), lowFraction))
            let high = max(low + 1, Int(Double(minBin) * pow(Double(maxBin) / Double(minBin), highFraction)))
            let upper = min(high, halfSize)

            // The loudest bin in the band, not the average of them. A mean
            // over a wide band is dominated by the many quiet bins beside the
            // peak, which makes wide bands both quieter and far steadier than
            // narrow ones — every bar ends up moving together and the whole
            // strip reads as a row of matching lines. The peak tracks whatever
            // is actually sounding in that range, so bands separate.
            var bandPeak: Float = 0
            magnitudes.withUnsafeBufferPointer { pointer in
                vDSP_maxv(pointer.baseAddress! + low, 1, &bandPeak, vDSP_Length(upper - low))
            }

            // Amplitude is perceptually logarithmic, so everything from here
            // on is in dB — which also makes a volume change a constant
            // offset, and so something the reference below can subtract out.
            //
            // The tilt goes in before the reference is taken, so it shapes the
            // bands relative to each other without shifting the overall level.
            let db = 20 * log10(max(Double(bandPeak), 1e-7))
            bandDb[band] = db + Double(band) * Self.tiltPerBand
            #if DEBUG
            rawDb[band] = db
            #endif
        }

        // Adapt the reference toward this frame's overall level, then measure
        // each band against it. This is what removes the dependence on
        // Spotify's own volume: turning Spotify down drops every band by the
        // same number of dB, the reference follows, and the difference — the
        // shape and the dynamics, which is all the waveform was ever trying
        // to show — is unchanged.
        //
        // Frozen during silence rather than left to sink, and floored, so a
        // pause doesn't end with the noise floor normalised up to full height.
        //
        // Each band is clamped to within 40dB of the loudest before it counts
        // toward the frame level. An empty band bottoms out at the 1e-7 guard,
        // i.e. -140dB, and a raw mean would let one such band drag the frame
        // level down ~16dB — inflating every *other* bar. A bass-heavy passage
        // with nothing up top would visibly swell the whole display. The clamp
        // rarely binds on real music and bounds the damage when it does.
        let frameFloor = (bandDb.max() ?? Self.referenceFloor) - 40
        let frameLevel = bandDb.reduce(0) { $0 + max($1, frameFloor) }
            / Double(bandCount)
        if !isSilent {
            let coefficient = frameLevel > reference
                ? Self.referenceAttack
                : Self.referenceRelease
            reference += (frameLevel - reference) * coefficient
            reference = max(reference, Self.referenceFloor)
        }

        if isSilent {
            for band in 0..<bandCount { newLevels[band] = 0 }
        } else {
            for band in 0..<bandCount {
                // +28 over a 53dB span puts a band sitting exactly at the
                // reference just past half the strip's height, and pegs one
                // running 25dB above it.
                //
                // This started at +30/50 — a 0.6 resting point with only 20dB
                // of headroom. Measured against real playback, bands sit
                // +15.5dB over the reference at p99, so the loudest passages
                // were within 5dB of the ceiling: at full volume the bars'
                // true peaks reached 0.97 of the strip and read as pinned.
                // The span is the knob that buys headroom — 53dB keeps the
                // loudest peaks around 0.88, clear of the ceiling but not so
                // far down that the waveform goes limp.
                let normalised = (bandDb[band] - reference + 28) / 53
                newLevels[band] = min(max(normalised, 0), 1)
            }
        }

        lock.lock()
        #if DEBUG
        referenceReadout = reference
        rawReadout = rawDb
        #endif
        for index in 0..<bandCount {
            let target = newLevels[index]
            // Fast attack, slow release — mirrors a physical VU meter and
            // stops the bars flickering on transients.
            let coefficient = target > smoothed[index] ? 0.55 : 0.12
            smoothed[index] += (target - smoothed[index]) * coefficient
            // Snap to a true zero once the release decay is below a
            // sub-pixel height. Exponential decay only approaches zero, and
            // without this the values keep changing in the 15th decimal place
            // forever — which reads as "changed" to the check above and
            // defeats the idle path during silence.
            if smoothed[index] < 0.0015 {
                smoothed[index] = 0
            }
            #if DEBUG
            levelPeaks[index] = max(levelPeaks[index], smoothed[index])
            #endif
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
