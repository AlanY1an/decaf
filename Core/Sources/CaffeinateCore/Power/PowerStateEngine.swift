// PowerStateEngine — the single in-process power-hold decision maker (plan 01).
//
// Responsibilities (plan 01 "PowerStateEngine 与 reconcile"):
// - Merge all hold sources through a [HoldSourceID: HoldRequest] registry: ANY
//   live, non-expired request means "want to hold".
// - Idempotent reconcile: under the same (requests, gates, now) a second call
//   makes ZERO PowerAsserting calls.
// - Wall-clock truth: expiry is a plain `deadline <= now()` comparison. The
//   boundary timer only wakes reconcile early — it carries no semantics, and a
//   missed/late timer never affects correctness (slept-through deadlines are
//   confirmed on the didWake reconcile).
// - Safety gates are SUSPEND semantics, not cancel: a closed gate releases the
//   assertion but preserves the request registry; re-opening resumes the hold.
// - Renewal is create-then-release at renewalInterval, and every assertion
//   carries assertionTimeout (default 30 min) + TimeoutActionRelease so powerd
//   self-heals even if this engine wedges. IOPMAssertionSetProperty is never
//   used (review decision R9).
// - Manual sessions are never persisted (review decision R2); crash cleanup is
//   powerd's job (assertions die with the process).

import Combine
import Foundation
import IOKit.pwr_mgt
import os

/// Shared logger for the "power" category (plan 01 "可观测性").
/// `log stream --predicate 'category == "power"'` is the field-debugging path.
enum PowerLog {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.caffeinate.app",
        category: "power"
    )
}

/// Coarse-grained HumanReadableReason strings (plan 01: set only at
/// create/renewal time, never updated per source change to avoid churn).
enum HoldReason {
    static let agents = "Keeping your Mac awake while AI agents work"
    static let manual = "Manual keep-awake session"
}

@MainActor
public final class PowerStateEngine: ObservableObject {
    // MARK: - Public state

    public enum Status: Equatable {
        /// No requests at all.
        case idle
        /// Holding the assertion for `sourceCount` live sources.
        case holding(sourceCount: Int)
        /// Requests exist but a safety gate suppresses holding (suspend, not
        /// cancel). `context` feeds the plan 04 UI (review decision R12).
        case suspended(by: SafetyGate, context: SuspensionContext)
    }

    /// Snapshot attached to `.suspended` (review decision R12).
    public struct SuspensionContext: Equatable, Sendable {
        /// nil on machines without a battery (or before the first snapshot).
        public var batteryPercent: Int?
        /// The currently effective threshold (SettingsStore-injected value).
        public var batteryThreshold: Int

        public init(batteryPercent: Int?, batteryThreshold: Int) {
            self.batteryPercent = batteryPercent
            self.batteryThreshold = batteryThreshold
        }
    }

    @Published public private(set) var status: Status = .idle

    /// The registered (non-expired) hold sources after the last reconcile.
    /// Read-only mirror of the request registry for the composition root
    /// (plan 01 PR-6): it detects manual expiry / willSleep drops here without
    /// reaching into the private registry.
    @Published public private(set) var activeSources: Set<HoldSourceID> = []

    /// Effective tuning. The runtime batteryThreshold comes from SettingsStore
    /// via `updateTuning` (review decision R3); defaults are PowerTuning's.
    public private(set) var tuning: PowerTuning

    // MARK: - Internal state (internal, not private, so tests inspect via @testable)

    /// The request registry. Merge semantics: any non-expired entry ⇒ hold.
    private(set) var requests: [HoldSourceID: HoldRequest] = [:]
    /// Gate snapshot. Battery hysteresis/override transitions are owned here
    /// (monitors only report raw snapshots).
    private(set) var gates = SafetyGates()

    private struct HeldAssertion {
        var id: IOPMAssertionID
        var createdAt: Date
    }

    private var held: [AssertionKind: HeldAssertion] = [:]
    private var lastBattery: BatterySnapshot?
    /// True between willSleep and didWake: no assertions are (re)created while
    /// the machine is going down, but agent requests stay registered.
    private var isSystemSleeping = false

    private let asserter: any PowerAsserting
    /// Injected wall clock (tests drive time explicitly; default real clock).
    private let now: () -> Date
    private var timer: DispatchSourceTimer?

    public init(
        asserter: any PowerAsserting,
        tuning: PowerTuning = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.asserter = asserter
        self.tuning = tuning
        self.now = now
    }

    deinit {
        timer?.cancel()
    }

    // MARK: - Requests

    /// Registers or replaces one source's request (last-write-wins per source),
    /// then reconciles. Manual activation while the battery gate is engaged is
    /// an informed override (KYA semantics, plan 01 gate table).
    public func setRequest(_ request: HoldRequest) {
        if request.source == .manual, gates.battery == .engaged, !gates.batteryOverridden {
            gates.batteryOverridden = true
            PowerLog.logger.log("battery gate overridden by explicit manual activation")
        }
        requests[request.source] = request
        reconcile()
    }

    /// Removes one source's request (no-op if absent), then reconciles.
    public func removeRequest(_ source: HoldSourceID) {
        requests.removeValue(forKey: source)
        if source == .manual {
            clearBatteryOverride(reason: "manual request removed")
        }
        reconcile()
    }

    // MARK: - Gates

    /// Raw gate mutation entry for the LPM / user-session monitors. Battery
    /// state should go through `updateBattery` (hysteresis lives there).
    public func updateGates(_ mutate: (inout SafetyGates) -> Void) {
        let old = gates
        mutate(&gates)
        if gates != old {
            PowerLog.logger.log(
                "gates changed: \(String(describing: old), privacy: .public) -> \(String(describing: self.gates), privacy: .public)"
            )
        }
        reconcile()
    }

    /// Battery gate transition function (plan 01 gate table; monitor reports
    /// snapshots only, all threshold/hysteresis/override logic is here):
    /// - engage: on battery AND percent < threshold (threshold 0 = gate off)
    /// - re-open: percent >= threshold + hysteresis, OR plugged in, OR no battery
    /// - natural re-open clears the manual override.
    public func updateBattery(_ snapshot: BatterySnapshot) {
        lastBattery = snapshot
        let old = gates.battery
        let new = batteryGateState(from: old, snapshot: snapshot)
        if new != old {
            gates.battery = new
            PowerLog.logger.log(
                "battery gate \(String(describing: old), privacy: .public) -> \(String(describing: new), privacy: .public) (percent: \(snapshot.percent), onBattery: \(snapshot.isOnBattery), threshold: \(self.tuning.batteryThreshold))"
            )
            if new == .open {
                clearBatteryOverride(reason: "battery gate re-opened")
            }
        }
        reconcile()
    }

    /// Injects new tuning (SettingsStore is the runtime source for
    /// batteryThreshold, review decision R3) and re-evaluates.
    public func updateTuning(_ newTuning: PowerTuning) {
        tuning = newTuning
        if let snapshot = lastBattery {
            updateBattery(snapshot) // re-runs the gate transition + reconcile
        } else {
            reconcile()
        }
    }

    private func batteryGateState(
        from current: SafetyGates.GateState,
        snapshot: BatterySnapshot
    ) -> SafetyGates.GateState {
        // No battery (desktops) or threshold 0 (gate disabled in settings):
        // the gate is permanently open.
        guard snapshot.hasBattery, tuning.batteryThreshold > 0 else { return .open }
        // Plugging in re-opens immediately.
        guard snapshot.isOnBattery else { return .open }
        switch current {
        case .open:
            return snapshot.percent < tuning.batteryThreshold ? .engaged : .open
        case .engaged:
            // Hysteresis: recover only at threshold + hysteresis (default 23).
            return snapshot.percent >= tuning.batteryRecoverThreshold ? .open : .engaged
        }
    }

    private func clearBatteryOverride(reason: String) {
        guard gates.batteryOverridden else { return }
        gates.batteryOverridden = false
        PowerLog.logger.log("battery override cleared (\(reason, privacy: .public))")
    }

    // MARK: - Sleep / wake

    /// willSleepNotification entry. A willSleep while we hold
    /// preventIdleSystemSleep is necessarily user-initiated or system-forced —
    /// never fight it (plan 01 "手动睡眠尊重"): release everything, drop the
    /// manual request (lid close = explicit intent to sleep; it does not revive
    /// on wake), KEEP agent requests (the detection layer confirms or sweeps
    /// them after wake).
    public func systemWillSleep() {
        PowerLog.logger.log("systemWillSleep: releasing assertions, dropping manual request, keeping agent requests")
        isSystemSleeping = true
        if requests.removeValue(forKey: .manual) != nil {
            clearBatteryOverride(reason: "manual request dropped on willSleep")
        }
        reconcile()
    }

    /// didWakeNotification entry: one reconcile confirms slept-through
    /// deadlines and re-holds for surviving requests.
    public func systemDidWake() {
        PowerLog.logger.log("systemDidWake: reconciling")
        isSystemSleeping = false
        reconcile()
    }

    // MARK: - Reconcile

    /// The idempotent settle path (plan 01 six-step algorithm). Every trigger
    /// source — request change, gate change, timer, didWake, clock change —
    /// funnels here; nothing else touches assertions.
    public func reconcile() {
        let current = now()

        // 1. Prune expired requests (wall clock is the only truth; `<=` keeps
        //    the deadline instant itself out of the hold — half-open interval).
        for (source, request) in requests {
            if case .at(let deadline) = request.expiry, deadline <= current {
                requests.removeValue(forKey: source)
                PowerLog.logger.log("request expired: \(String(describing: source), privacy: .public)")
                if source == .manual {
                    clearBatteryOverride(reason: "manual request expired")
                }
            }
        }

        // 2. Gate composition.
        let blocked = gates.blocksHolding

        // 3. Desired assertion kinds (MVP: system-sleep only; V1.x appends the
        //    display kind by preference).
        let wantsHold = !requests.isEmpty
        let desired: Set<AssertionKind> =
            (wantsHold && !blocked && !isSystemSleeping) ? [.preventIdleSystemSleep] : []

        // 4. Settle held vs desired.
        for (kind, assertion) in held where !desired.contains(kind) {
            asserter.release(assertion.id)
            held.removeValue(forKey: kind)
            PowerLog.logger.log("released assertion \(assertion.id) (\(kind.rawValue, privacy: .public))")
        }
        for kind in desired {
            if let existing = held[kind] {
                // Renewal: create-then-release, no gap (review decision R9 —
                // never IOPMAssertionSetProperty).
                if current.timeIntervalSince(existing.createdAt) >= tuning.renewalInterval {
                    if let newID = asserter.create(
                        kind: kind, reason: holdReason(), timeout: tuning.assertionTimeout
                    ) {
                        asserter.release(existing.id)
                        held[kind] = HeldAssertion(id: newID, createdAt: current)
                        PowerLog.logger.log(
                            "renewed assertion \(existing.id) -> \(newID) (\(kind.rawValue, privacy: .public))"
                        )
                    } else {
                        // Keep the old assertion; its own timeout still backstops us.
                        PowerLog.logger.error("renewal create failed; keeping assertion \(existing.id)")
                    }
                }
            } else {
                if let id = asserter.create(
                    kind: kind, reason: holdReason(), timeout: tuning.assertionTimeout
                ) {
                    held[kind] = HeldAssertion(id: id, createdAt: current)
                    PowerLog.logger.log(
                        "created assertion \(id) (\(kind.rawValue, privacy: .public), timeout: \(self.tuning.assertionTimeout)s)"
                    )
                } else {
                    // Failure is retried on the next reconcile trigger.
                    PowerLog.logger.error("assertion create failed (\(kind.rawValue, privacy: .public))")
                }
            }
        }

        // 5. Recompute status; publish only on change.
        let newStatus = computeStatus(wantsHold: wantsHold, blocked: blocked)
        if newStatus != status {
            status = newStatus
        }
        let sourceIDs = Set(requests.keys)
        if sourceIDs != activeSources {
            activeSources = sourceIDs
        }

        // 6. Re-arm the boundary timer (nearest deadline / renewal instant).
        rearmTimer(now: current)
    }

    private func computeStatus(wantsHold: Bool, blocked: Bool) -> Status {
        guard wantsHold, !isSystemSleeping else { return .idle }
        guard blocked else { return .holding(sourceCount: requests.count) }
        let gate: SafetyGate
        if gates.battery == .engaged, !gates.batteryOverridden {
            gate = .lowBattery
        } else if gates.lowPowerMode == .engaged {
            gate = .lowPowerMode
        } else {
            gate = .userSessionInactive
        }
        let percent: Int?
        if let battery = lastBattery, battery.hasBattery {
            percent = battery.percent
        } else {
            percent = nil
        }
        return .suspended(
            by: gate,
            context: SuspensionContext(batteryPercent: percent, batteryThreshold: tuning.batteryThreshold)
        )
    }

    private func holdReason() -> String {
        let hasAgentSource = requests.keys.contains { source in
            switch source {
            case .agentSession, .agentFallback:
                return true
            case .manual, .schedule:
                return false
            }
        }
        return hasAgentSource ? HoldReason.agents : HoldReason.manual
    }

    /// Arms a single one-shot timer at min(nearest request deadline, nearest
    /// renewal instant); cancels it when neither exists. The timer only wakes
    /// reconcile — it carries no semantics (plan 01 step 6).
    private func rearmTimer(now current: Date) {
        var nextFire: Date?
        func consider(_ candidate: Date) {
            if let existing = nextFire {
                if candidate < existing { nextFire = candidate }
            } else {
                nextFire = candidate
            }
        }
        for request in requests.values {
            if case .at(let deadline) = request.expiry {
                consider(deadline)
            }
        }
        for assertion in held.values {
            consider(assertion.createdAt.addingTimeInterval(tuning.renewalInterval))
        }

        timer?.cancel()
        timer = nil
        guard let fireAt = nextFire else { return }

        let interval = max(0, fireAt.timeIntervalSince(current))
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(wallDeadline: .now() + interval, leeway: .seconds(1))
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.reconcile()
            }
        }
        source.resume()
        timer = source
    }
}
