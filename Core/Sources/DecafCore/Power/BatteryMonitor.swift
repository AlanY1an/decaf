// BatteryMonitor — thin IOPS adapter (plan 01 "监视器适配层", modeled on KYA's
// KYABatteryMonitor.m). It ONLY reports BatterySnapshot values; the threshold /
// hysteresis / override decisions are the engine's battery gate transition
// function (pure, unit-testable). Callbacks are hopped to the main thread
// before reaching the engine.

import Foundation
import IOKit.ps
import os

/// What the battery monitor reports (plan 01).
public struct BatterySnapshot: Equatable, Sendable {
    /// False on desktops — the battery gate stays permanently open.
    public var hasBattery: Bool
    /// True while discharging (on battery power).
    public var isOnBattery: Bool
    /// Charge percentage 0...100 (meaningless when hasBattery is false).
    public var percent: Int

    public init(hasBattery: Bool, isOnBattery: Bool, percent: Int) {
        self.hasBattery = hasBattery
        self.isOnBattery = isOnBattery
        self.percent = percent
    }
}

@MainActor
public final class BatteryMonitor {
    /// Fired on the main thread with the fresh snapshot (initial value on
    /// start(), then on every IOPS change notification).
    public var onSnapshot: ((BatterySnapshot) -> Void)?

    private var runLoopSource: CFRunLoopSource?

    public init() {}

    /// Convenience wiring: forward snapshots into the engine's battery gate.
    public func bind(to engine: PowerStateEngine) {
        onSnapshot = { [weak engine] snapshot in
            engine?.updateBattery(snapshot)
        }
    }

    /// Attaches IOPSNotificationCreateRunLoopSource to the main run loop and
    /// delivers the initial snapshot. Call `stop()` before releasing the
    /// monitor (the IOPS context holds an unretained reference to self).
    public func start() {
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let unmanaged = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            // IOPS callbacks land on the run loop we attached to, but hop
            // explicitly so the engine is always entered from the main queue.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    monitor.publishSnapshot()
                }
            }
        }, context) else {
            PowerLog.logger.error("IOPSNotificationCreateRunLoopSource failed; battery gate will stay open")
            return
        }
        let source = unmanaged.takeRetainedValue()
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        publishSnapshot()
    }

    public func stop() {
        guard let source = runLoopSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = nil
    }

    private func publishSnapshot() {
        onSnapshot?(Self.readSnapshot())
    }

    /// Reads the current power-source state via the IOPS API
    /// (IOPSCopyPowerSourcesInfo → IOPSCopyPowerSourcesList →
    /// IOPSGetPowerSourceDescription, keys per plan 01 / KYABatteryMonitor.m).
    public nonisolated static func readSnapshot() -> BatterySnapshot {
        let noBattery = BatterySnapshot(hasBattery: false, isOnBattery: false, percent: 100)
        guard
            let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return noBattery
        }
        for source in list {
            guard
                let description = IOPSGetPowerSourceDescription(info, source)?
                    .takeUnretainedValue() as? [String: Any],
                (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                (description[kIOPSIsPresentKey] as? Bool) ?? true
            else { continue }

            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = max > 0
                ? Int((Double(current) / Double(max) * 100).rounded())
                : current
            let isOnBattery =
                (description[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            return BatterySnapshot(hasBattery: true, isOnBattery: isOnBattery, percent: percent)
        }
        return noBattery
    }
}
