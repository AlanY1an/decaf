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

    /// Stops the manual session only; other hold sources are untouched.
    func stopManual()

    /// User confirmed "keep awake anyway" in the low-battery override dialog
    /// (KYA semantics, plan 01 battery gate override).
    func confirmLowBatteryOverride()
}
