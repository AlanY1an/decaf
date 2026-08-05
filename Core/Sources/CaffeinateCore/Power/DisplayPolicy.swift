// DisplayPolicy — how a hold treats the DISPLAY while the system is kept awake
// (plan 01 reserved `AssertionKind.preventIdleDisplaySleep`, now given a writer).
//
// Two behaviours, one default:
//   .allowSleep (DEFAULT) — system stays awake, the display sleeps normally.
//                           This is the pre-existing, hardcoded MVP behaviour.
//   .keepOn                — the display is kept awake as well.
//
// The engine merges policies as a UNION over active holds (see
// PowerStateEngine.reconcile step 3): the system assertion is always held,
// the display assertion iff ANY live, non-suspended hold asks for `.keepOn`.
//
// UI copy lives here on purpose: the menu, the settings pane and the
// unavailable-reason tooltip must never drift apart.

import Foundation

/// Per-hold display behaviour. Persisted (SettingsStore.defaultDisplayPolicy)
/// and carried on every HoldRequest.
public enum DisplayPolicy: String, Codable, Sendable, CaseIterable, Equatable {
    /// System awake, display sleeps normally. Factory default.
    case allowSleep
    /// Display stays on too (adds kIOPMAssertPreventUserIdleDisplaySleep).
    case keepOn

    /// Title-case label for menu items (macOS menu capitalization). The menu
    /// shows `.keepOn` as a single check-markable switch, so this is written to
    /// read as a command: "Keep Display On".
    public var menuTitle: String {
        switch self {
        case .allowSleep: return "Allow Display to Sleep"
        case .keepOn: return "Keep Display On"
        }
    }

    /// Label for the settings popup. Deliberately NOT `menuTitle`: a popup lists
    /// the states a thing can be in, so its values are state phrases ("Stays
    /// on") answering the row label ("Display while keeping awake"), where a
    /// command phrase ("Keep Display On") would read as an action misfiled into
    /// a menu of nouns.
    public var settingsTitle: String {
        switch self {
        case .allowSleep: return "Sleeps normally"
        case .keepOn: return "Stays on"
        }
    }

    /// The assertion this policy adds on top of the always-held system
    /// assertion; nil when it adds nothing.
    public var additionalAssertionKind: AssertionKind? {
        switch self {
        case .allowSleep: return nil
        case .keepOn: return .preventIdleDisplaySleep
        }
    }
}

/// Copy for the "Turn Off Display Now" action (kept next to DisplayPolicy so
/// the whole display-related vocabulary lives in one file).
public enum DisplayActionCopy {
    public static let turnOffDisplayNow = "Turn Off Display Now"

    /// Why the action is disabled. Shown as the menu item's tooltip /
    /// secondary label when `AppStateSnapshot.canTurnOffDisplayNow` is false.
    ///
    /// Rationale (the CRITICAL INTERACTION): while the display assertion is
    /// held, `pmset displaysleepnow` blanks the screen and the assertion wakes
    /// it right back up — the app would fight itself. So the action is
    /// unavailable rather than silently changing the user's chosen policy.
    ///
    /// Built from `menuTitle` so it always names the control the user is
    /// actually looking at: the cure is to switch off the very item sitting one
    /// line above the disabled one. (Naming a second, non-existent menu item
    /// would send them hunting for it.)
    public static let turnOffDisplayUnavailableReason =
        "Unavailable while \u{201C}\(DisplayPolicy.keepOn.menuTitle)\u{201D} is on — switch it off first."
}
