//
//  BluetoothBatteryMonitor.swift
//
//  Battery levels for connected Bluetooth peripherals — headphones, a
//  keyboard, a mouse.
//
//  Two halves, because no single API does both:
//
//  * **When** a device connects comes from IOBluetooth, which hands out a
//    real notification object. No polling.
//  * **What** its battery reads comes from `system_profiler SPBluetoothDataType`,
//    which is a subprocess. The obvious in-process route — `BatteryPercent`
//    and friends under `AppleDeviceManagementHIDEventService` in the IO
//    registry — is a dead end on current macOS: `ioreg -r -k BatteryPercent`
//    returns nothing even with a device connected and visibly reporting.
//
//  The subprocess costs ~0.1s, which is fine on a connect event and would not
//  be fine on a timer. So this class never polls: it reads on a connect, and
//  on an explicit `refreshLowDevices()` call (the Mac being plugged in, which
//  is the moment a flat pair of headphones is worth mentioning).
//
//  `-json` rather than the default text output on purpose. The keys
//  (`device_batteryLevelLeft`, `device_minorType`) are stable identifiers;
//  the text output's labels ("Left Battery Level:") are display strings and
//  have moved between releases.
//

import Foundation
import IOBluetooth

@MainActor
final class BluetoothBatteryMonitor: NSObject {
    /// A device connected and reports a level worth showing.
    var onDeviceConnected: ((PeripheralBattery) -> Void)?

    /// The lowest connected device that is at or below
    /// `PeripheralBattery.lowThreshold`, in answer to `refreshLowDevices()`.
    /// At most one, so plugging in the Mac can't produce a queue of toasts.
    var onLowDevice: ((PeripheralBattery) -> Void)?

    private var connectNotification: IOBluetoothUserNotification?
    private var isRunning = false

    /// A `system_profiler` read is already in flight. Connects arrive in
    /// bursts (a case opening reports both buds), and there is no point
    /// running the subprocess twice for one answer.
    private var readInFlight = false

    /// Addresses seen connecting since the last read completed, so a burst
    /// collapses into one subprocess and still reports every device in it.
    private var pendingAddresses: Set<String> = []

    /// Registering for connect notifications immediately fires them for
    /// devices that are *already* connected — which is useful state, but as an
    /// event it would mean a toast for your headphones every time Isle
    /// launches. Connects are ignored until this passes.
    private var armedAt: Date = .distantFuture
    private static let launchGrace: TimeInterval = 3

    /// A freshly connected device hasn't necessarily published its battery
    /// characteristic yet, so the read is deferred rather than immediate.
    private static let connectSettleDelay: TimeInterval = 2

    /// The subprocess is short-lived and local, but it is still a subprocess:
    /// if it wedges, drop it rather than leaking a `Process` per connect.
    /// `nonisolated` because the watchdog that uses it runs off the main
    /// actor, alongside the process itself.
    private nonisolated static let readTimeout: TimeInterval = 5

    private var settleTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        armedAt = Date().addingTimeInterval(Self.launchGrace)
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )
        if connectNotification == nil {
            NSLog("Isle: IOBluetooth connect registration failed — device batteries disabled")
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        settleTask?.cancel()
        settleTask = nil
        connectNotification?.unregister()
        connectNotification = nil
        pendingAddresses.removeAll()
    }

    // MARK: - Events

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification,
                                       device: IOBluetoothDevice) {
        guard isRunning, Date() >= armedAt else { return }
        // IOBluetooth writes addresses with hyphens; system_profiler uses
        // colons. Normalise here so the two halves can be matched.
        guard let address = device.addressString?.replacingOccurrences(of: "-", with: ":")
            .uppercased()
        else { return }

        pendingAddresses.insert(address)
        scheduleRead()
    }

    /// Read every connected device and report the flattest one, if it's low
    /// enough to be worth an unprompted mention. Called when the Mac is
    /// plugged in — see `PowerMonitor.onPluggedIn`.
    func refreshLowDevices() {
        guard isRunning, !readInFlight else { return }
        readInFlight = true
        Task { [weak self] in
            let devices = await Self.readConnectedDevices()
            guard let self else { return }
            self.readInFlight = false
            guard self.isRunning else { return }
            if let lowest = devices
                .filter({ $0.percent <= PeripheralBattery.lowThreshold })
                .min(by: { $0.percent < $1.percent }) {
                self.onLowDevice?(lowest)
            }
        }
    }

    /// Coalesces a burst of connects into one deferred read.
    private func scheduleRead() {
        guard settleTask == nil else { return }
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.connectSettleDelay))
            guard !Task.isCancelled, let self, self.isRunning else { return }
            self.settleTask = nil

            let wanted = self.pendingAddresses
            self.pendingAddresses.removeAll()
            guard !wanted.isEmpty else { return }

            let devices = await Self.readConnectedDevices()
            guard self.isRunning else { return }
            // Only the devices this burst was about. A level is reported or it
            // isn't — a device that publishes nothing produces no toast at
            // all, rather than a placeholder.
            for device in devices where wanted.contains(device.address) {
                self.onDeviceConnected?(device)
            }
        }
    }

    // MARK: - system_profiler

    /// Runs the subprocess off the main thread and parses its JSON. Returns
    /// an empty array on any failure — a missing battery is the normal case
    /// here, so nothing about it is worth surfacing to the user.
    nonisolated static func readConnectedDevices() async -> [PeripheralBattery] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: parse(runProfiler()))
            }
        }
    }

    private nonisolated static func runProfiler() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = nil

        do {
            try process.run()
        } catch {
            NSLog("Isle: system_profiler failed to launch: \(error)")
            return nil
        }

        // Read before waiting: the output is a few KB, well under the pipe
        // buffer, but reading after `waitUntilExit` is the classic way to
        // deadlock if it ever grows.
        let watchdog = DispatchWorkItem { [weak process] in
            if process?.isRunning == true { process?.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + readTimeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        return process.terminationStatus == 0 ? data : nil
    }

    /// The shape is
    /// `{"SPBluetoothDataType":[{"device_connected":[{"<name>":{...}}]}]}` —
    /// each device is a single-key dictionary whose key is its display name.
    nonisolated static func parse(_ data: Data?) -> [PeripheralBattery] {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return [] }

        var result: [PeripheralBattery] = []
        for controller in controllers {
            guard let connected = controller["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                guard let (name, value) = entry.first,
                      let properties = value as? [String: Any],
                      let address = properties["device_address"] as? String,
                      let percent = level(from: properties)
                else { continue }
                result.append(PeripheralBattery(
                    name: name,
                    address: address.uppercased(),
                    percent: percent,
                    minorType: properties["device_minorType"] as? String
                ))
            }
        }
        return result
    }

    /// The level worth reporting for one device.
    ///
    /// Single-battery devices use `device_batteryLevelMain`. Earbuds report
    /// left, right and case separately: the lower of left/right is the one
    /// that ends the session, and the case is excluded because it isn't what
    /// runs out on you mid-call. If nothing parses, the device has no
    /// reportable battery and is dropped entirely.
    private nonisolated static func level(from properties: [String: Any]) -> Int? {
        if let main = percent(properties["device_batteryLevelMain"])
            ?? percent(properties["device_batteryLevel"]) {
            return main
        }
        let buds = [
            percent(properties["device_batteryLevelLeft"]),
            percent(properties["device_batteryLevelRight"]),
        ].compactMap { $0 }
        return buds.min()
    }

    /// Values arrive as strings with a percent sign ("78%").
    private nonisolated static func percent(_ value: Any?) -> Int? {
        guard let string = value as? String else { return value as? Int }
        return Int(string.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
    }
}
