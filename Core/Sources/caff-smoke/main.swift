// caff-smoke — dev-only assertion smoke tool (plan 01 PR-1, plan 06 §1).
//
// Usage: swift run caff-smoke [seconds] [display]   (default 60, system only)
//
// Takes real assertions named "Caffeinate" through IOPMPowerAsserter, prints
// the assertion IDs, holds for N seconds so the operator can verify the entries
// in `pmset -g assertions` (grep Caffeinate), then releases and exits. Never
// ships in the app bundle.
//
// Passing `display` additionally takes preventIdleDisplaySleep — the
// DisplayPolicy.keepOn assertion. Worth running once on real hardware: unit
// tests only ever see the fake asserter, so nothing else proves IOKit accepts
// our assertion-type string for that kind. It keeps the screen lit for N
// seconds; it never blanks anything.

import Foundation
import CaffeinateCore

let arguments = CommandLine.arguments.dropFirst()
let seconds = arguments.first.flatMap(Int.init) ?? 60
let wantsDisplay = arguments.contains("display")

let asserter = IOPMPowerAsserter()
let kinds: [AssertionKind] = wantsDisplay
    ? [.preventIdleSystemSleep, .preventIdleDisplaySleep]
    : [.preventIdleSystemSleep]

var held: [(AssertionKind, IOPMAssertionID)] = []
for kind in kinds {
    guard let id = asserter.create(
        kind: kind,
        reason: "caff-smoke assertion smoke test",
        timeout: TimeInterval(max(seconds, 1)) + 30
    ) else {
        FileHandle.standardError.write(Data("caff-smoke: \(kind.rawValue) create failed\n".utf8))
        for (_, id) in held { asserter.release(id) }
        exit(1)
    }
    held.append((kind, id))
    print("caff-smoke: holding \(kind.rawValue) assertion id=\(id) for \(seconds)s")
}

print("caff-smoke: verify with `pmset -g assertions | grep Caffeinate`")
Thread.sleep(forTimeInterval: TimeInterval(seconds))
for (kind, id) in held {
    asserter.release(id)
    print("caff-smoke: released \(kind.rawValue) assertion id=\(id)")
}
