// Safety gate value types (plan 01 "安全门 SafetyGates").
// Gates are SUSPEND semantics, not cancel: when a gate engages, assertions are
// released but the request registry is preserved; when the gate re-opens the
// hold resumes automatically. Gate transition logic (hysteresis, override
// lifecycle) lives in the engine (plan 01 PR-3/PR-4), not here.

/// Which safety gate is suppressing the hold (plan 01 `PowerStateEngine.SafetyGate`;
/// defined at module scope so UI/state types can reference it without the engine).
public enum SafetyGate: Equatable, Sendable {
    case lowBattery
    case lowPowerMode
    case userSessionInactive
}

/// Snapshot of all safety gates (plan 01).
public struct SafetyGates: Equatable, Sendable {
    /// Low-battery gate (threshold + hysteresis evaluated by the engine).
    public var battery: GateState = .open
    /// Explicit user override of the battery gate (KYA semantics): set when the
    /// user manually re-activates while the gate is engaged; cleared when the
    /// manual request ends or the gate naturally re-opens.
    public var batteryOverridden = false
    /// Low Power Mode gate. No user override — the honest path is turning LPM off.
    public var lowPowerMode: GateState = .open
    /// Fast user switching: false while our login session is inactive.
    public var userSessionActive = true

    public enum GateState: Equatable, Sendable {
        case open
        case engaged
    }

    /// Composition rule (plan 01): true when any gate suppresses holding.
    public var blocksHolding: Bool {
        (battery == .engaged && !batteryOverridden)
            || lowPowerMode == .engaged
            || !userSessionActive
    }

    public init(
        battery: GateState = .open,
        batteryOverridden: Bool = false,
        lowPowerMode: GateState = .open,
        userSessionActive: Bool = true
    ) {
        self.battery = battery
        self.batteryOverridden = batteryOverridden
        self.lowPowerMode = lowPowerMode
        self.userSessionActive = userSessionActive
    }
}
