// DisplayController — the "turn the screen off right now" IO seam.
//
// Same discipline as PowerAsserting (plan 01 "断言层"): the real implementation
// is the only thing that touches the outside world, everything else talks to
// the protocol so unit tests never blank a screen.
//
// Implementation choice: `/usr/bin/pmset displaysleepnow`. The pmset man page
// scopes its root requirement to *modifying settings*; `displaysleepnow` is an
// action and works from an unprivileged context (this is what keepresso does).
// No IOKit private API, no helper tool, no new dependency.
//
// Interaction rule (owned by the composition root, not by this adapter): while
// the display assertion is held (`DisplayPolicy.keepOn` in effect), blanking
// the display would immediately be undone by our own assertion. The caller
// must refuse; this adapter stays dumb.

import Foundation
import os

/// Puts the display to sleep immediately (the user's "screen off now" action).
public protocol DisplaySleeping: AnyObject {
    /// Issues the request. Returns false when it could not even be issued
    /// (implementations log and never throw).
    @discardableResult
    func sleepDisplayNow() -> Bool
}

/// Real implementation: runs `/usr/bin/pmset displaysleepnow`.
public final class PmsetDisplaySleeper: DisplaySleeping {
    /// Absolute path — never resolved through PATH.
    public static let defaultExecutablePath = "/usr/bin/pmset"

    private let executablePath: String

    public init(executablePath: String = PmsetDisplaySleeper.defaultExecutablePath) {
        self.executablePath = executablePath
    }

    /// Launches pmset and returns as soon as it is running: the caller is the
    /// main actor driving a menu action, so we never block on the child. A
    /// non-zero exit is reported asynchronously through the log.
    @discardableResult
    public func sleepDisplayNow() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["displaysleepnow"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            if finished.terminationStatus != 0 {
                PowerLog.logger.error(
                    "pmset displaysleepnow exited with status \(finished.terminationStatus)"
                )
            }
        }
        do {
            try process.run()
        } catch {
            PowerLog.logger.error(
                "pmset displaysleepnow failed to launch: \(String(describing: error), privacy: .public)"
            )
            return false
        }
        PowerLog.logger.log("pmset displaysleepnow issued")
        return true
    }
}

/// Test double. Lives in the library target for the same reason
/// FakePowerAsserter does: every test suite shares one fake, and production
/// code never instantiates it.
public final class FakeDisplaySleeper: DisplaySleeping {
    /// Number of accepted "turn the display off" requests.
    public private(set) var callCount = 0
    /// What `sleepDisplayNow()` reports back.
    public var succeeds = true

    public init() {}

    @discardableResult
    public func sleepDisplayNow() -> Bool {
        callCount += 1
        return succeeds
    }
}
