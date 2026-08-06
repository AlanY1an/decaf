// ProbeCostTests — what `ClaudeCodeIntegration.probe()` is allowed to cost
// (plan 03 §3.2).
//
// The regression: probe ran on the main actor at every launch and at every
// visit to the Agents tab. When the binary is not in one of the fixed candidate
// directories it falls through to `$SHELL -lic 'command -v claude'` — a login
// shell sourcing the user's whole profile, on a 10 s fuse — and then pays 3 s
// more for `--version`. For anyone using nvm, fnm, volta, asdf or mise (i.e.
// most people who install a Node CLI) that was up to 13 seconds of beach ball
// with no menu bar icon on screen.
//
// Two halves, both pinned here:
//   1. the candidate list actually covers those installs, so the shell is never
//      launched for them;
//   2. `--version` is probed once per binary, not once per probe.
// The third half — running the whole thing off the main actor — is what the
// Sendable conformance at the bottom exists for.

import Foundation
import Testing
@testable import CaffeinateCore
import HookWire

// MARK: - Test doubles

/// Minimal read-only file system: a set of executables and the directory tree
/// implied by them.
private final class ProbeFS: FileSystem {
    enum FSError: Error { case unsupported, missing(String) }

    private var executables: Set<String> = []
    private var directories: Set<String> = ["/"]

    func addExecutable(_ path: String) {
        executables.insert(path)
        var current = (path as NSString).deletingLastPathComponent
        while current != "/", !current.isEmpty {
            directories.insert(current)
            current = (current as NSString).deletingLastPathComponent
        }
    }

    func fileExists(atPath path: String) -> Bool {
        executables.contains(path) || directories.contains(path)
    }
    func isExecutableFile(atPath path: String) -> Bool { executables.contains(path) }
    func readData(atPath path: String) throws -> Data { throw FSError.missing(path) }
    func writeDataAtomically(_ data: Data, toPath path: String) throws { throw FSError.unsupported }
    func copyItem(atPath sourcePath: String, toPath destinationPath: String) throws {
        throw FSError.unsupported
    }
    func removeItem(atPath path: String) throws { throw FSError.unsupported }
    func createDirectory(atPath path: String) throws { directories.insert(path) }

    func contentsOfDirectory(atPath path: String) throws -> [String] {
        guard directories.contains(path) else { throw FSError.missing(path) }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        var names: Set<String> = []
        for entry in executables.union(directories) where entry.hasPrefix(prefix) {
            if let first = entry.dropFirst(prefix.count).split(separator: "/").first {
                names.insert(String(first))
            }
        }
        return Array(names)
    }
}

private final class CountingRunner: ProcessRunning {
    private(set) var calls: [(executable: String, arguments: [String])] = []
    var versionOutput: String? = "2.1.37 (Claude Code)"

    func runCapturingOutput(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> String? {
        calls.append((executable, arguments))
        return arguments == ["--version"] ? versionOutput : nil
    }

    var shellLookupCount: Int { calls.filter { $0.arguments.first == "-lic" }.count }
    var versionCallCount: Int { calls.filter { $0.arguments == ["--version"] }.count }
}

private let home = "/Users/tester"

private func makeIntegration(
    fileSystem: FileSystem,
    runner: ProcessRunning
) -> ClaudeCodeIntegration {
    ClaudeCodeIntegration(
        fileSystem: fileSystem,
        processRunner: runner,
        configuration: .init(
            homeDirectory: home,
            bundledBridgePath: "/Applications/Caffeinate.app/Contents/Helpers/caff-bridge",
            bridgeVersion: "1.0.0",
            shellPath: "/bin/zsh"
        )
    )
}

// MARK: - The candidate directories

@Suite struct ProbeFindsTheBinaryWithoutALoginShell {

    /// Every one of these used to fall through to `$SHELL -lic`.
    static let installLocations: [String] = [
        home + "/.claude/local/bin",          // Claude Code's own installer
        home + "/.volta/bin",                 // volta
        home + "/.asdf/shims",                // asdf
        home + "/.local/share/mise/shims",    // mise
        home + "/.fnm/aliases/default/bin",   // fnm
        home + "/Library/pnpm",               // pnpm
        home + "/.yarn/bin",                  // yarn
        home + "/.deno/bin",                  // deno
        home + "/.nvm/versions/node/v22.11.0/bin", // nvm (no shim directory)
    ]

    @Test(arguments: installLocations)
    func aBinaryInAKnownLocationCostsNoShell(directory: String) {
        let fs = ProbeFS()
        let runner = CountingRunner()
        fs.addExecutable(directory + "/claude")

        let status = makeIntegration(fileSystem: fs, runner: runner).probe()

        #expect(status == .detected(version: "2.1.37"))
        #expect(runner.shellLookupCount == 0, "\(directory) must not need a login shell")
    }

    @Test func nvmPrefersTheNewestInstalledNode() {
        let fs = ProbeFS()
        let runner = CountingRunner()
        let versions = home + "/.nvm/versions/node"
        for version in ["v9.4.0", "v20.9.0", "v22.11.0"] {
            fs.addExecutable(versions + "/" + version + "/bin/claude")
        }

        let integration = makeIntegration(fileSystem: fs, runner: runner)
        #expect(integration.probe() == .detected(version: "2.1.37"))
        #expect(runner.shellLookupCount == 0)
        // Numeric ordering, newest first: v9 must not outrank v20/v22.
        let nvmCandidates = integration.candidateDirectories.filter { $0.hasPrefix(versions) }
        #expect(nvmCandidates == [
            versions + "/v22.11.0/bin",
            versions + "/v20.9.0/bin",
            versions + "/v9.4.0/bin",
        ])
    }

    @Test func aMissingNvmDirectoryIsNotAnError() {
        let fs = ProbeFS()
        let runner = CountingRunner()
        fs.addExecutable("/opt/homebrew/bin/claude")

        #expect(makeIntegration(fileSystem: fs, runner: runner).probe()
            == .detected(version: "2.1.37"))
        #expect(runner.shellLookupCount == 0)
    }

    @Test func anUnknownLocationStillFallsBackToTheLoginShell() {
        // The slow path is not deleted, only made rare: a genuinely exotic PATH
        // must still resolve.
        let fs = ProbeFS()
        let runner = CountingRunner()
        #expect(makeIntegration(fileSystem: fs, runner: runner).probe() == .notDetected)
        #expect(runner.shellLookupCount == 1)
    }
}

// MARK: - The version fuse

@Suite struct ProbeVersionIsCached {

    @Test func versionIsAskedForOncePerBinary() {
        let fs = ProbeFS()
        let runner = CountingRunner()
        fs.addExecutable(home + "/.claude/local/bin/claude")
        let integration = makeIntegration(fileSystem: fs, runner: runner)

        // Launch, then two visits to the Agents tab.
        #expect(integration.probe() == .detected(version: "2.1.37"))
        #expect(integration.probe() == .detected(version: "2.1.37"))
        #expect(integration.probe() == .detected(version: "2.1.37"))

        #expect(runner.versionCallCount == 1, "a 3-second fuse per Agents-tab visit buys nothing")
    }

    @Test func anUnparseableVersionIsCachedToo() {
        let fs = ProbeFS()
        let runner = CountingRunner()
        runner.versionOutput = nil // the fuse blew, or the binary said nothing
        fs.addExecutable(home + "/.claude/local/bin/claude")
        let integration = makeIntegration(fileSystem: fs, runner: runner)

        #expect(integration.probe() == .detected(version: nil))
        #expect(integration.probe() == .detected(version: nil))
        #expect(runner.versionCallCount == 1)
    }
}

// MARK: - Off the main actor

@Suite struct ProbeRunsOffTheMainActor {

    /// The app hops the probe onto a detached task so the main actor is never
    /// blocked on a login shell. That hop requires this conformance; if it were
    /// removed, this file would stop compiling — which is the point.
    @Test func integrationCanCrossToABackgroundTask() async {
        let fs = ProbeFS()
        let runner = CountingRunner()
        fs.addExecutable(home + "/.claude/local/bin/claude")
        let integration: ClaudeCodeIntegration = makeIntegration(fileSystem: fs, runner: runner)
        let sendable: any Sendable = integration
        #expect(sendable is ClaudeCodeIntegration)

        let status = await Task.detached { integration.probe() }.value
        #expect(status == .detected(version: "2.1.37"))
    }
}
