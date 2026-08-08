// EphemeralDefaults — throwaway UserDefaults suites that clean up after themselves.
//
// `UserDefaults(suiteName:)` writes a real plist into ~/Library/Preferences and
// nothing ever removes it. Every test here minted a fresh UUID suite so runs
// could not collide, which is right, but the plists outlived the process: a
// single `swift test` left hundreds behind, and 4,462 had piled up by the time
// anyone looked (2026-08-07, including a long tail under the retired
// dev.caffeinate.* prefixes). They are inert — but they are litter in a
// directory that belongs to the user, not to this test suite.
//
// Cleanup runs at process exit rather than per test. The call sites hand back a
// bare UserDefaults, so there is no object whose lifetime marks "this test is
// finished", and Swift Testing has no global teardown hook. `atexit` takes a C
// function pointer and therefore cannot capture, which is why the registry is a
// file-scope global rather than something injected.

import Foundation

/// Suite names created this process, removed together when it exits.
private let ephemeralSuites = EphemeralSuiteRegistry()

private final class EphemeralSuiteRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []

    func add(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        names.append(name)
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        let preferences = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
        for name in names {
            UserDefaults.standard.removePersistentDomain(forName: name)
            // removePersistentDomain is not enough on its own: it empties the
            // domain, but cfprefsd leaves the file behind as an empty 42-byte
            // plist. The one call site that already did the "right" thing with
            // `defer { removePersistentDomain }` was still leaking a file per
            // run for exactly this reason. Unlink it too.
            try? FileManager.default.removeItem(
                at: preferences.appendingPathComponent("\(name).plist")
            )
        }
        names.removeAll()
    }
}

/// Installed once, on first use. A lazy global is initialised exactly once and
/// thread-safely, which is the whole reason this is a `let` and not a flag.
private let atexitHandlerInstalled: Bool = {
    atexit { ephemeralSuites.removeAll() }
    return true
}()

/// A UserDefaults on a suite unique to this call, whose plist is removed when
/// the test process exits.
///
/// `label` only makes the file legible while a run is in flight — uniqueness
/// comes from the UUID, so two tests sharing a label still get separate stores.
func makeEphemeralDefaults(_ label: String) -> UserDefaults {
    _ = atexitHandlerInstalled
    let name = "io.github.alany1an.decaf.tests.\(label).\(UUID().uuidString)"
    ephemeralSuites.add(name)
    // Force-unwrapped deliberately: UserDefaults(suiteName:) only returns nil
    // for a name that collides with a reserved domain, which a UUID cannot.
    return UserDefaults(suiteName: name)!
}
