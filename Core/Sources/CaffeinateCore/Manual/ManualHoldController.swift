// ManualHoldController — thin controller for the manual keep-awake source
// (plan 05 D2, review decision R1). It translates user actions (preset
// durations, "until HH:MM", infinite) into plan 01's HoldRequest(.manual,
// expiry:) and writes them to PowerStateEngine via setRequest/removeRequest.
//
// Discipline (plan 05 / rulings R1, R2):
// - Owns NO timer, NO expiry evaluation, NO source composition. Deadline
//   pruning, slept-through confirmation (didWake) and the boundary timer are
//   owned solely by PowerStateEngine.reconcile() (plan 01).
// - Wall-clock folding happens exactly once, at activation: durations become
//   `.at(now + duration)`, "until HH:MM" becomes the NEXT occurrence of that
//   wall-clock time as an absolute Date (plan 05 D4). The stored Date is never
//   reinterpreted on timezone or clock changes — expiry is a plain
//   `deadline <= now` comparison inside the engine.
// - Repeated activation is last-write-wins per source (the engine registry
//   keys by HoldSourceID); `.infinite` clears the deadline (`.indefinite`).
// - Manual sessions are never persisted (ruling R2): quit releases everything.
// - Left-click semantics (which click maps to activate/deactivate) are owned
//   by plan 04 §4; deactivate() only removes the `.manual` source and never
//   touches agent or schedule sources (engine merge semantics).

import Foundation

@MainActor
public final class ManualHoldController {
    private let engine: PowerStateEngine
    /// Injected wall clock (same pattern as plan 01's engine; tests drive it).
    private let now: () -> Date
    private let calendar: Calendar

    public init(
        engine: PowerStateEngine,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.engine = engine
        self.now = now
        self.calendar = calendar
    }

    /// Activates (or re-activates) the manual session. Calling again while
    /// active overwrites the deadline (last-write-wins). Activating while the
    /// battery gate is engaged counts as an informed override — that rule
    /// lives in the engine's setRequest path (plan 01 gate table).
    ///
    /// `displayPolicy` is the caller's current choice (the composition root
    /// passes SettingsStore.defaultDisplayPolicy); it defaults to the
    /// pre-existing behaviour so older call sites are unchanged.
    ///
    /// Returns the UI-facing snapshot (mode + folded absolute expiry) so the
    /// composition root can publish ManualState without re-deriving the fold.
    /// Liveness stays the engine's truth: the snapshot is a value, not state.
    @discardableResult
    public func activate(
        _ mode: ManualMode,
        displayPolicy: DisplayPolicy = .allowSleep
    ) -> ManualState {
        let expiry = fold(mode)
        engine.setRequest(
            HoldRequest(source: .manual, expiry: expiry, displayPolicy: displayPolicy)
        )
        switch expiry {
        case .indefinite:
            return ManualState(mode: mode, expiry: nil)
        case .at(let deadline):
            return ManualState(mode: mode, expiry: deadline)
        }
    }

    /// Ends the manual session only; all other hold sources are untouched.
    public func deactivate() {
        engine.removeRequest(.manual)
    }

    /// Wall-clock folding (plan 05 D4). Pure with respect to the injected
    /// clock/calendar; no Date() and no timers in here.
    private func fold(_ mode: ManualMode) -> Expiry {
        switch mode {
        case .infinite:
            return .indefinite
        case .duration(let seconds):
            return .at(now().addingTimeInterval(seconds))
        case .until(let timeOfDay):
            // The user picked a wall-clock time (hour:minute). Take its NEXT
            // occurrence strictly after now — if today's instance has already
            // passed, that is tomorrow's (plan 05 T2). `.nextTime` also covers
            // the DST spring-forward gap by picking the first valid instant.
            let components = calendar.dateComponents([.hour, .minute], from: timeOfDay)
            if let next = calendar.nextDate(
                after: now(),
                matching: components,
                matchingPolicy: .nextTime
            ) {
                return .at(next)
            }
            // Unreachable with a sane calendar; fall back to the raw instant
            // rather than holding forever.
            return .at(timeOfDay)
        }
    }
}
