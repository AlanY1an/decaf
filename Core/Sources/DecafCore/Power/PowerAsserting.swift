// PowerAsserting — the IOKit abstraction seam (plan 01 "断言层").
// The real implementation (IOPMPowerAsserter, plan 01 PR-1) is the only file allowed to
// call into IOKit power-management APIs; unit tests use a fake conforming to this protocol
// so they never touch the real powerd.

import Foundation
import IOKit.pwr_mgt

/// Abstraction over IOPM assertion creation/release (plan 01).
///
/// Contract (plan 01 §"断言层"):
/// - `create` returns nil on failure (implementations log, never fatal). The
///   assertion self-releases after `timeout` seconds via
///   `kIOPMAssertionTimeoutActionRelease` — the self-healing backstop.
/// - `release` of an already-timed-out/invalid ID returns an error from IOKit;
///   implementations ignore any non-success result (log only, never throw).
public protocol PowerAsserting: AnyObject {
    /// Creates an assertion of the given kind. Returns nil on failure.
    func create(kind: AssertionKind, reason: String, timeout: TimeInterval) -> IOPMAssertionID?

    /// Releases a previously created assertion. Non-success IOKit results are ignored.
    func release(_ id: IOPMAssertionID)
}
