// FakePowerAsserter — records the PowerAsserting call sequence for unit tests
// (plan 01 PR-2). It lives in the library target (not the test target) so all
// sibling test suites share one fake; production code never instantiates it.
//
// "持有" in the plan 06 §4 test matrix means `active` is non-empty. Sequence
// assertions (e.g. renewal's new create BEFORE the old release) read `calls`.

import Foundation
import IOKit.pwr_mgt

public final class FakePowerAsserter: PowerAsserting {
    public enum Call: Equatable {
        case create(id: IOPMAssertionID, kind: AssertionKind, reason: String, timeout: TimeInterval)
        case release(id: IOPMAssertionID)
    }

    /// Ordered record of every create/release call.
    public private(set) var calls: [Call] = []
    /// Currently live (created, not yet released) assertions.
    public private(set) var active: [IOPMAssertionID: AssertionKind] = [:]
    /// When true, the next create fails (returns nil) and the flag resets.
    public var failNextCreate = false

    private var nextID: IOPMAssertionID = 1

    public init() {}

    public var createCount: Int {
        calls.reduce(0) { count, call in
            if case .create = call { return count + 1 }
            return count
        }
    }

    public var releaseCount: Int { calls.count - createCount }

    public func create(kind: AssertionKind, reason: String, timeout: TimeInterval) -> IOPMAssertionID? {
        if failNextCreate {
            failNextCreate = false
            return nil
        }
        let id = nextID
        nextID += 1
        active[id] = kind
        calls.append(.create(id: id, kind: kind, reason: reason, timeout: timeout))
        return id
    }

    public func release(_ id: IOPMAssertionID) {
        active.removeValue(forKey: id)
        calls.append(.release(id: id))
    }

    /// Clears the recorded call log (live assertions are kept) so a test can
    /// assert "zero PowerAsserting calls from this point on".
    public func resetCallLog() {
        calls.removeAll()
    }
}
