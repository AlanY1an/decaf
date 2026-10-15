// LidSleepController — decides when "Keep running with the lid closed" holds
// the system's SleepDisabled setting (plan 07).
//
// The switch is a modifier on the existing hold, never a hold of its own:
// SleepDisabled = 1 only while ALL of these are true —
//
//   - the user switched it on;
//   - the root helper is installed and approved;
//   - the engine is actually holding (not idle, not suspended by a safety gate —
//     so Low Power Mode, low battery and fast user switching win here too);
//   - the battery is not below the helper's floor on battery power.
//
// Every change re-derives that one answer and moves the helper toward it, one
// request at a time. The helper enforces its own reverts (disconnect, missed
// heartbeats, battery floor), so this side never has to be right about a crash.

import Foundation
import LidSleepXPC

/// What the helper can do right now, as the app's ServiceManagement adapter
/// sees it.
public enum LidSleepHelperAvailability: Equatable, Sendable {
    case ready
    case notRegistered
    case needsApproval
    case unavailable(LidSleepUnavailableReason)
}

public enum LidSleepUnavailableReason: Equatable, Sendable {
    /// Ad-hoc builds have no team to pin the XPC peer to.
    case unsignedBuild
    /// launchd's background-item database breaks daemons of apps run elsewhere.
    case notInApplications
    case registrationFailed(String)
}

/// The switch as the menu and Settings show it.
public enum LidSleepStatus: Equatable, Sendable {
    case off
    case unavailable(LidSleepUnavailableReason)
    case needsApproval
    /// On, but nothing is being held, so closing the lid still sleeps.
    case standby
    case starting
    case active
    case pausedLowBattery
    case failed(String)

    public var isOn: Bool { self != .off }
}

/// The root helper behind the switch. The app's adapter talks
/// SMAppService + XPC; tests use `FakeLidSleepHelper`.
@MainActor
public protocol LidSleepHelperConnecting: AnyObject {
    var availability: LidSleepHelperAvailability { get }
    /// Registers the daemon if needed and reports the availability after.
    @discardableResult
    func register() -> LidSleepHelperAvailability
    func openApprovalSettings()
    /// Asks the helper to set SleepDisabled = 1 for this app.
    func acquire() async throws
    func release() async
    func heartbeat()
    /// The connection dropped; the helper has already reverted any hold.
    var onConnectionLost: (@MainActor () -> Void)? { get set }
}

@MainActor
public final class LidSleepController {
    public private(set) var status: LidSleepStatus = .off
    /// Fired after `status` changes.
    public var onChange: (() -> Void)?

    private var helper: (any LidSleepHelperConnecting)?
    private let notifier: (any UserNotifying)?
    private let heartbeatInterval: TimeInterval
    private let approvalPollInterval: TimeInterval

    private var enabled: Bool
    private var engineHolding = false
    private var battery = BatterySnapshot(hasBattery: false, isOnBattery: false, percent: 100)
    /// The helper confirmed our hold and we have not released it.
    private var held = false
    private var operation: Task<Void, Never>?
    /// Last acquire failure; cleared by anything that is worth retrying for.
    private var failure: String?
    private var heartbeatTask: Task<Void, Never>?
    private var approvalPoll: Task<Void, Never>?

    public init(
        enabled: Bool,
        helper: (any LidSleepHelperConnecting)?,
        notifier: (any UserNotifying)? = nil,
        heartbeatInterval: TimeInterval = LidSleepXPC.heartbeatInterval,
        approvalPollInterval: TimeInterval = 2
    ) {
        self.enabled = enabled
        self.helper = helper
        self.notifier = notifier
        self.heartbeatInterval = heartbeatInterval
        self.approvalPollInterval = approvalPollInterval
        self.helper?.onConnectionLost = { [weak self] in self?.connectionLost() }
        reconcile()
    }

    // MARK: Inputs

    public func setEnabled(_ on: Bool) {
        enabled = on
        failure = nil
        if on, helper?.availability == .notRegistered {
            helper?.register()
        }
        reconcile()
    }

    /// The engine's verdict: holding, as opposed to idle or suspended.
    public func updateEngineHolding(_ holding: Bool) {
        guard holding != engineHolding else { return }
        engineHolding = holding
        if holding { failure = nil }
        reconcile()
    }

    public func updateBattery(_ snapshot: BatterySnapshot) {
        guard snapshot != battery else { return }
        battery = snapshot
        reconcile()
    }

    /// Re-reads the helper's availability (Settings appearing, app activation).
    public func refresh() {
        reconcile()
    }

    public func openApprovalSettings() {
        helper?.openApprovalSettings()
    }

    // MARK: Decision

    private var availability: LidSleepHelperAvailability {
        helper?.availability ?? .unavailable(.unsignedBuild)
    }

    private var batteryBelowFloor: Bool {
        battery.hasBattery && battery.isOnBattery && battery.percent < LidSleepXPC.batteryFloorPercent
    }

    private var wantsHold: Bool {
        enabled && availability == .ready && engineHolding && !batteryBelowFloor && failure == nil
    }

    private func reconcile() {
        let wanted = wantsHold
        if operation == nil, let helper {
            if wanted && !held {
                operation = Task { [weak self] in
                    do {
                        try await helper.acquire()
                        self?.held = true
                    } catch {
                        self?.failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                    self?.operationFinished()
                }
            } else if !wanted && held {
                operation = Task { [weak self] in
                    await helper.release()
                    self?.held = false
                    self?.operationFinished()
                }
            }
        }
        updateHeartbeat()
        updateApprovalPoll()
        publish()
    }

    private func operationFinished() {
        operation = nil
        reconcile()
    }

    private func connectionLost() {
        guard held else { return }
        // The helper reverts on disconnect; re-acquire if we still should.
        held = false
        reconcile()
    }

    private func publish() {
        let new: LidSleepStatus
        if !enabled {
            new = .off
        } else {
            switch availability {
            case .unavailable(let reason): new = .unavailable(reason)
            case .notRegistered, .needsApproval: new = .needsApproval
            case .ready:
                if batteryBelowFloor { new = .pausedLowBattery }
                else if let failure { new = .failed(failure) }
                else if !engineHolding { new = .standby }
                else { new = held ? .active : .starting }
            }
        }
        guard new != status else { return }
        let old = status
        status = new
        if old == .active, new == .pausedLowBattery {
            notifier?.post(LidSleepCopy.lowBatteryNotice)
        }
        onChange?()
    }

    // MARK: Timers

    private func updateHeartbeat() {
        if held, heartbeatTask == nil {
            let interval = heartbeatInterval
            heartbeatTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    guard let self, !Task.isCancelled else { return }
                    self.helper?.heartbeat()
                }
            }
        } else if !held {
            heartbeatTask?.cancel()
            heartbeatTask = nil
        }
    }

    /// Approval happens in System Settings, which tells nobody; poll while
    /// the switch is on and waiting for it.
    private func updateApprovalPoll() {
        let waiting = enabled && (availability == .needsApproval || availability == .notRegistered)
        if waiting, approvalPoll == nil {
            let interval = approvalPollInterval
            approvalPoll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    guard let self, !Task.isCancelled else { return }
                    self.reconcile()
                }
            }
        } else if !waiting {
            approvalPoll?.cancel()
            approvalPoll = nil
        }
    }

    /// Test hook: waits for the in-flight helper request, if any.
    func waitForPendingOperation() async {
        while let operation {
            await operation.value
        }
    }
}

/// Records calls instead of touching launchd; lives in the library for the
/// same reason `FakePowerAsserter` does.
@MainActor
public final class FakeLidSleepHelper: LidSleepHelperConnecting {
    public var availability: LidSleepHelperAvailability
    public var availabilityAfterRegister: LidSleepHelperAvailability = .needsApproval
    public var acquireError: Error?
    public private(set) var acquireCount = 0
    public private(set) var releaseCount = 0
    public private(set) var heartbeatCount = 0
    public private(set) var registerCount = 0
    public private(set) var openedApprovalSettings = 0
    /// SleepDisabled as the fake helper holds it.
    public private(set) var holding = false
    public var onConnectionLost: (@MainActor () -> Void)?

    public init(availability: LidSleepHelperAvailability = .ready) {
        self.availability = availability
    }

    @discardableResult
    public func register() -> LidSleepHelperAvailability {
        registerCount += 1
        availability = availabilityAfterRegister
        return availability
    }

    public func openApprovalSettings() { openedApprovalSettings += 1 }

    public func acquire() async throws {
        acquireCount += 1
        if let acquireError { throw acquireError }
        holding = true
    }

    public func release() async {
        releaseCount += 1
        holding = false
    }

    public func heartbeat() { heartbeatCount += 1 }

    /// Simulates the helper dying: it reverts, and the app hears about it.
    public func dropConnection() {
        holding = false
        onConnectionLost?()
    }
}
