// caff-smoke — dev-only assertion smoke tool (plan 01 PR-1, plan 06 §1).
//
// Usage: swift run caff-smoke [seconds]   (default 60)
//
// Takes a real preventIdleSystemSleep assertion named "Caffeinate" through
// IOPMPowerAsserter, prints the assertion ID, holds for N seconds so the
// operator can verify the entry in `pmset -g assertions` (grep Caffeinate),
// then releases and exits. Never ships in the app bundle.

import Foundation
import CaffeinateCore

let seconds = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 60
let asserter = IOPMPowerAsserter()

guard let id = asserter.create(
    kind: .preventIdleSystemSleep,
    reason: "caff-smoke assertion smoke test",
    timeout: TimeInterval(max(seconds, 1)) + 30
) else {
    FileHandle.standardError.write(Data("caff-smoke: assertion create failed\n".utf8))
    exit(1)
}

print("caff-smoke: holding preventIdleSystemSleep assertion id=\(id) for \(seconds)s")
print("caff-smoke: verify with `pmset -g assertions | grep Caffeinate`")
Thread.sleep(forTimeInterval: TimeInterval(seconds))
asserter.release(id)
print("caff-smoke: released assertion id=\(id)")
