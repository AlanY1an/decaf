// AppCommands — the single channel of user actions from the UI into CaffeinateCore
// (plan 04 §1). The UI never mutates state directly. The implementation is owned by
// the composition root (plan 01 PR-6, review decision R11).

import Foundation

/// All user actions the UI can issue.
@MainActor
public protocol AppCommands: AnyObject {
    /// Left-click semantics = the state table in plan 04 §4 (MVP rows 1/2/4).
    /// Hard rule: a left click never releases an agent hold.
    func toggleManual()

    /// Starts (or restarts) manual mode with the given mode.
    func startManual(_ mode: ManualMode)

    /// Starts (or restarts) manual mode ending at an ABSOLUTE instant the UI
    /// already resolved against the wall clock — the menu's "Until 6:00 PM"
    /// item and its "Until…" submenu (see `UntilOptions`).
    ///
    /// Distinct from `startManual(.until(_:))`, which takes a time of day and
    /// re-derives the next occurrence of it. Here the deadline is final: the
    /// user picked an instant off a list of clock times and that instant is
    /// what gets held, whatever happens to the clock afterwards.
    ///
    /// A point-of-use choice, NOT a preference: this never writes the stored
    /// "until" default (Settings › General). Contrast `setDisplayPolicy`,
    /// which is explicitly a default-changer.
    ///
    /// A deadline that is not in the future is refused — see the composition
    /// root's implementation for why (a menu can outlive the hour it was drawn
    /// from).
    func holdUntil(_ deadline: Date)

    /// Stops the manual session only; other hold sources are untouched.
    func stopManual()

    /// User confirmed "keep awake anyway" in the low-battery override dialog
    /// (KYA semantics, plan 01 battery gate override).
    func confirmLowBatteryOverride()

    /// Chooses the display behaviour: applies to the running manual hold
    /// (and to live agent holds, which always follow the default) and is
    /// persisted as the default for the next hold.
    func setDisplayPolicy(_ policy: DisplayPolicy)

    /// Turns agent auto keep-awake on or off, and persists the choice.
    ///
    /// On (the default) is the product: the Mac stays awake while an agent is
    /// working. Off makes this a plain keep-awake utility — agents are ignored
    /// and only the manual controls hold anything.
    ///
    /// Switching OFF is immediate and unconditional: every agent-derived hold is
    /// released on the spot, with no release grace window. The grace window
    /// exists to absorb the gap between two turns of an agent the user still
    /// wants held; a user who just said they do not want this at all is not in
    /// that gap, and making them wait three minutes for a switch they flipped
    /// would teach them the switch does not work.
    ///
    /// Manual holds are untouched in both directions — this switch has no
    /// opinion about a hold the user started by hand.
    func setAgentAutoKeepAwake(_ enabled: Bool)

    /// Blanks the display immediately (`pmset displaysleepnow`).
    ///
    /// Refused — logged, no process launched — while
    /// `AppStateSnapshot.canTurnOffDisplayNow` is false, i.e. while the display
    /// assertion is held: blanking then would be undone by our own assertion.
    /// The menu item is expected to be disabled in that state, with
    /// `turnOffDisplayUnavailableReason` as the explanation; this refusal is
    /// the belt-and-braces half of the same rule.
    func turnOffDisplayNow()
}
