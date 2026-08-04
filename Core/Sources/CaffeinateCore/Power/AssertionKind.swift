// AssertionKind — the IOPM assertion types Caffeinate may hold (plan 01, review decision R9/R10).
// Case naming follows plan 01: `preventIdleSystemSleep` (deliberately NOT named after the
// rejected kIOPMAssertionTypePreventSystemSleep, which is AC-only and deprecated).

/// The kinds of power assertions the engine can create.
public enum AssertionKind: String, Sendable, CaseIterable, Equatable {
    /// kIOPMAssertPreventUserIdleSystemSleep — the only kind used in MVP.
    /// Effective on battery; the display may still sleep.
    case preventIdleSystemSleep

    /// kIOPMAssertPreventUserIdleDisplaySleep — reserved for the V1.x
    /// "keep display awake" preference. No writer in MVP.
    case preventIdleDisplaySleep

    /// The IOKit assertion type string to pass to
    /// `IOPMAssertionCreateWithDescription`. Values match
    /// `kIOPMAssertionTypePreventUserIdleSystemSleep` /
    /// `kIOPMAssertionTypePreventUserIdleDisplaySleep` so the contract layer
    /// itself does not need to import IOKit.
    public var ioKitAssertionType: String {
        switch self {
        case .preventIdleSystemSleep:
            return "PreventUserIdleSystemSleep"
        case .preventIdleDisplaySleep:
            return "PreventUserIdleDisplaySleep"
        }
    }
}
