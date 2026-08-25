//
//  MediaRemoteCommands.swift
//
//  Sending playback commands to whatever owns the now-playing session.
//
//  Unlike *reading* now-playing info — which Apple gated behind an
//  entitlement around macOS 15.4 and which Isle therefore does
//  out-of-process, see MediaRemoteAdapterClient — the command-sending half
//  of MediaRemote still works in-process. So this is a plain dynamic
//  lookup against the private framework.
//
//  Every symbol is optional. If a future macOS removes one, the matching
//  control reports unavailable and hides rather than taking the app down.
//

import Foundation

final class MediaRemoteCommands {
    static let shared = MediaRemoteCommands()

    /// MediaRemote's command identifiers.
    private enum Command: Int {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case stop = 3
        case nextTrack = 4
        case previousTrack = 5
    }

    private typealias SendCommandFn = @convention(c) (Int, AnyObject?) -> Bool
    private typealias SetElapsedTimeFn = @convention(c) (Double) -> Void
    private typealias SetShuffleModeFn = @convention(c) (Int) -> Void
    private typealias SetRepeatModeFn = @convention(c) (Int) -> Void

    private let sendCommand: SendCommandFn?
    private let setElapsedTime: SetElapsedTimeFn?
    private let setShuffleMode: SetShuffleModeFn?
    private let setRepeatMode: SetRepeatModeFn?

    private init() {
        guard let bundle = CFBundleCreate(
            kCFAllocatorDefault,
            URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework") as CFURL
        ) else {
            sendCommand = nil
            setElapsedTime = nil
            setShuffleMode = nil
            setRepeatMode = nil
            NSLog("Isle: could not open MediaRemote.framework — transport controls disabled")
            return
        }

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = CFBundleGetFunctionPointerForName(bundle, name as CFString) else {
                NSLog("Isle: MediaRemote symbol \(name) unavailable")
                return nil
            }
            return unsafeBitCast(pointer, to: type)
        }

        sendCommand = symbol("MRMediaRemoteSendCommand", as: SendCommandFn.self)
        setElapsedTime = symbol("MRMediaRemoteSetElapsedTime", as: SetElapsedTimeFn.self)
        setShuffleMode = symbol("MRMediaRemoteSetShuffleMode", as: SetShuffleModeFn.self)
        setRepeatMode = symbol("MRMediaRemoteSetRepeatMode", as: SetRepeatModeFn.self)
    }

    // MARK: - Availability

    var canControlPlayback: Bool { sendCommand != nil }
    var canSeek: Bool { setElapsedTime != nil }
    var canShuffle: Bool { setShuffleMode != nil }
    var canRepeat: Bool { setRepeatMode != nil }

    // MARK: - Transport

    @discardableResult
    func togglePlayPause() -> Bool { send(.togglePlayPause) }

    @discardableResult
    func play() -> Bool { send(.play) }

    @discardableResult
    func pause() -> Bool { send(.pause) }

    @discardableResult
    func nextTrack() -> Bool { send(.nextTrack) }

    @discardableResult
    func previousTrack() -> Bool { send(.previousTrack) }

    func seek(to seconds: TimeInterval) {
        setElapsedTime?(max(0, seconds))
    }

    func setShuffle(_ enabled: Bool) {
        // MediaRemote's shuffle constants match the repeat ones: 1 is off,
        // 3 is on across the whole collection.
        setShuffleMode?(enabled ? 3 : 1)
    }

    func setRepeat(_ mode: RepeatMode) {
        setRepeatMode?(mode.rawValue)
    }

    private func send(_ command: Command) -> Bool {
        guard let sendCommand else { return false }
        return sendCommand(command.rawValue, nil)
    }
}
