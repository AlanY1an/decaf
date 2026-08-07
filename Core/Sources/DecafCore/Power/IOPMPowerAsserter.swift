// IOPMPowerAsserter — the real PowerAsserting implementation (plan 01 PR-1).
// This is the ONLY file that calls IOKit power-management APIs; everything else
// goes through the PowerAsserting seam so unit tests never touch powerd.
//
// Parameter contract (plan 01 "断言层"):
// - AssertionType maps from AssertionKind (never the deprecated, AC-only
//   kIOPMAssertionTypePreventSystemSleep).
// - Name is the fixed string "Decaf" — the greppable anchor in
//   `pmset -g assertions` used by the acceptance script.
// - HumanReadableReason is the caller's coarse summary, set only at
//   create/renewal time.
// - Timeout + kIOPMAssertionTimeoutActionRelease make powerd self-release the
//   assertion even if our engine wedges (self-healing backstop).
// - Crash cleanup requires nothing here: powerd reclaims assertions when the
//   owning process dies.

import Foundation
import IOKit.pwr_mgt
import os

public final class IOPMPowerAsserter: PowerAsserting {
    /// Fixed assertion Name shown by `pmset -g assertions` / Activity Monitor.
    public static let assertionName = "Decaf"

    public init() {}

    public func create(kind: AssertionKind, reason: String, timeout: TimeInterval) -> IOPMAssertionID? {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithDescription(
            kind.ioKitAssertionType as CFString,
            Self.assertionName as CFString,
            nil, // Details
            reason as CFString, // HumanReadableReason
            nil, // LocalizationBundlePath
            timeout,
            kIOPMAssertionTimeoutActionRelease as CFString,
            &id
        )
        guard result == kIOReturnSuccess else {
            // Never fatal (plan 01): log and report failure to the engine,
            // which retries on the next reconcile.
            PowerLog.logger.error(
                "IOPMAssertionCreateWithDescription(\(kind.rawValue, privacy: .public)) failed: 0x\(String(UInt32(bitPattern: result), radix: 16), privacy: .public)"
            )
            return nil
        }
        return id
    }

    public func release(_ id: IOPMAssertionID) {
        let result = IOPMAssertionRelease(id)
        if result != kIOReturnSuccess {
            // Expected for IDs already reclaimed by TimeoutActionRelease —
            // ignore (log only, never throw), per the PowerAsserting contract.
            PowerLog.logger.log(
                "IOPMAssertionRelease(\(id)) returned 0x\(String(UInt32(bitPattern: result), radix: 16), privacy: .public) (ignored)"
            )
        }
    }
}
