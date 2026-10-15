// decaf-lid-helper — the root LaunchDaemon behind "Keep running with the lid
// closed" (plan 07). Embedded at Decaf.app/Contents/MacOS/decaf-lid-helper and
// registered by the app through SMAppService.daemon.
//
// It does one thing: hold SleepDisabled = 1 while a signed Decaf asks for it,
// and put it back to 0 on every way that can stop being true. `SleepDisabled`
// is system-wide and survives the app, so a leftover 1 means a Mac that never
// sleeps — in a bag, that is a heat problem. Every path back to 0 is here:
//
//   - the app releases (its hold ended, or the switch went off);
//   - the app's connection drops (quit, crash, kill);
//   - the app stops heartbeating (hung) for `heartbeatTimeout`;
//   - the battery falls below the floor on battery power;
//   - the helper starts and finds a 1 nobody holds (boot after a power loss).
//
// launchd starts it at boot (RunAtLoad, for the last check) and on mach lookup;
// it exits once idle, so no root process lingers while nothing is held.

import Foundation
import LidSleepXPC
import os

private let log = Logger(subsystem: LidSleepXPC.appIdentifier, category: "lid-helper")

final class SleepGuard {
    let queue = DispatchQueue(label: "io.github.alany1an.decaf.lid-helper.guard")

    /// Connections that asked to hold, with their last sign of life.
    private var holders: [ObjectIdentifier: Date] = [:]
    private var connectionCount = 0
    private var idleExit: DispatchWorkItem?

    // MARK: Connection requests (all on `queue`)

    func acquire(_ key: ObjectIdentifier) -> (Bool, String?) {
        queue.sync {
            guard !LidSleepBattery.isBelowFloor() else {
                return (false, "battery below \(LidSleepXPC.batteryFloorPercent)%")
            }
            holders[key] = Date()
            guard SleepDisabledSetting.write(true) else {
                holders[key] = nil
                if holders.isEmpty { SleepDisabledSetting.write(false) }
                log.error("could not set SleepDisabled")
                return (false, "the sleep setting could not be changed")
            }
            log.log("SleepDisabled = 1 (\(self.holders.count, privacy: .public) holder(s))")
            return (true, nil)
        }
    }

    func heartbeat(_ key: ObjectIdentifier) {
        queue.async { [self] in
            if holders[key] != nil { holders[key] = Date() }
        }
    }

    func release(_ key: ObjectIdentifier) {
        queue.sync {
            guard holders.removeValue(forKey: key) != nil else { return }
            if holders.isEmpty { revert("released by Decaf") }
        }
    }

    func connectionOpened() {
        queue.async { [self] in
            connectionCount += 1
            idleExit?.cancel()
            idleExit = nil
        }
    }

    func connectionEnded(_ key: ObjectIdentifier) {
        queue.async { [self] in
            connectionCount = max(0, connectionCount - 1)
            if holders.removeValue(forKey: key) != nil, holders.isEmpty {
                revert("Decaf disconnected")
            }
            scheduleIdleExitIfIdle()
        }
    }

    // MARK: Autonomous checks

    func startupCheck() {
        queue.sync {
            if SleepDisabledSetting.read() == true { revert("found at startup with no hold") }
            scheduleIdleExitIfIdle()
        }
    }

    /// Runs on `queue` every few seconds, independent of any XPC traffic, so a
    /// wedged app or a lost invalidation still ends in a revert.
    func sentinelTick() {
        let now = Date()
        let stale = holders.filter { now.timeIntervalSince($0.value) > LidSleepXPC.heartbeatTimeout }
        for key in stale.keys { holders[key] = nil }
        if !holders.isEmpty, LidSleepBattery.isBelowFloor() {
            holders.removeAll()
            revert("battery below \(LidSleepXPC.batteryFloorPercent)%")
            return
        }
        if !stale.isEmpty, holders.isEmpty {
            revert("Decaf stopped responding")
        } else if holders.isEmpty, SleepDisabledSetting.read() == true {
            revert("set with no hold")
        }
    }

    func exitForUpgrade() {
        queue.async { [self] in
            if SleepDisabledSetting.read() == true { revert("helper upgrade") }
            log.log("exiting for upgrade")
            exit(0)
        }
    }

    /// Must run on `queue`.
    private func revert(_ reason: String) {
        let ok = SleepDisabledSetting.write(false)
        log.log("SleepDisabled = 0 (\(reason, privacy: .public)); confirmed: \(ok, privacy: .public)")
    }

    /// Must run on `queue`. launchd relaunches the helper on the next lookup.
    private func scheduleIdleExitIfIdle() {
        guard connectionCount == 0, holders.isEmpty, idleExit == nil else { return }
        let item = DispatchWorkItem { [self] in
            guard connectionCount == 0, holders.isEmpty else { return }
            if SleepDisabledSetting.read() == true { revert("idle exit") }
            exit(0)
        }
        idleExit = item
        queue.asyncAfter(deadline: .now() + 30, execute: item)
    }
}

final class HelperService: NSObject, DecafLidHelperXPC {
    private let guardian: SleepGuard
    private let key: ObjectIdentifier

    init(guardian: SleepGuard, key: ObjectIdentifier) {
        self.guardian = guardian
        self.key = key
    }

    func helperRevision(reply: @escaping (String) -> Void) { reply(LidSleepXPC.revision) }

    func acquire(reply: @escaping (Bool, String?) -> Void) {
        let result = guardian.acquire(key)
        reply(result.0, result.1)
    }

    func heartbeat() { guardian.heartbeat(key) }

    func release(reply: @escaping () -> Void) {
        guardian.release(key)
        reply()
    }

    func exitForUpgrade() { guardian.exitForUpgrade() }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let guardian: SleepGuard
    private let requirement: String?

    init(guardian: SleepGuard) {
        self.guardian = guardian
        self.requirement = LidSleepXPC.requirement(forPeer: LidSleepXPC.appIdentifier)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Any local process can look this service up; the requirement is what
        // keeps the switch Decaf's alone. An unsigned helper has none to apply
        // and therefore accepts nobody.
        guard let requirement else {
            log.error("helper has no signing team; refusing connection from pid \(connection.processIdentifier)")
            return false
        }
        connection.setCodeSigningRequirement(requirement)
        let key = ObjectIdentifier(connection)
        connection.exportedInterface = NSXPCInterface(with: DecafLidHelperXPC.self)
        connection.exportedObject = HelperService(guardian: guardian, key: key)
        connection.invalidationHandler = { [guardian] in guardian.connectionEnded(key) }
        guardian.connectionOpened()
        connection.resume()
        return true
    }
}

let guardian = SleepGuard()
guardian.startupCheck()

let delegate = ListenerDelegate(guardian: guardian)
let listener = NSXPCListener(machServiceName: LidSleepXPC.machServiceName)
listener.delegate = delegate
listener.resume()

let sentinel = DispatchSource.makeTimerSource(queue: guardian.queue)
sentinel.schedule(deadline: .now() + 10, repeating: 10)
sentinel.setEventHandler { guardian.sentinelTick() }
sentinel.resume()

dispatchMain()
