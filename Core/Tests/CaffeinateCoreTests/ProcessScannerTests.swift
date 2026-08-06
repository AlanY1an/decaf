// ProcessScannerTests — plan 02 §3's L3 enumeration, the half of
// `AgentHoldMode.whileRunning` that makes the mode true without hooks.
//
// The coordinator's side of this seam (what a scan MEANS: holds, staleness,
// coverage, the stuck interaction) is pinned in AgentHoldModeTests. This suite
// covers the half that lives below the seam and that nothing else can see:
//
// 1. **What counts as an agent, and what must not.** In `.whileRunning` a
//    false positive is a Mac that does not sleep for as long as the impostor
//    runs, and nothing in the app can contradict it — the process really is
//    there. So the matcher is tested as a table with the near misses spelled
//    out, not just the hits.
// 2. **A failed probe never becomes a positive.** Every "cannot tell" path
//    (exited mid-scan, another user's process, no argv) has to drop the pid.
// 3. **When the scanner is allowed to run at all**, which is what keeps the
//    default mode's cost at exactly zero.
// 4. **That the syscalls are right**, against this machine's real process
//    table. A libproc wrapper that compiles is not a libproc wrapper that
//    works, and the buffer arithmetic (bytes vs entries) is the kind of thing
//    only a real call catches.

import Darwin
import Foundation
import Testing
@testable import AgentDetection
@testable import CaffeinateCore
import HookWire

// MARK: - Matching

@Suite struct AgentProcessMatching {

    private func agent(_ path: String, _ argv: [String]? = nil) -> AgentKind? {
        AgentProcessMatcher.agent(forExecutablePath: path, arguments: { argv })
    }

    /// The install shapes that exist in the wild, and the ones that look like
    /// them and are not. Written as one table because the interesting content
    /// is the boundary between the two halves.
    @Test func theMatcherTable() {
        let hits: [(String, [String]?, AgentKind)] = [
            // A native binary or a Homebrew shim: the file is called `claude`.
            ("/opt/homebrew/bin/claude", nil, .claudeCode),
            ("/Users/tester/.claude/local/bin/claude", nil, .claudeCode),
            ("/usr/local/bin/codex", nil, .codex),
            ("/opt/homebrew/bin/opencode", nil, .opencode),
            // npm install: the executable is the runtime, and only argv says
            // which of this Mac's dozen Node processes this one is.
            (
                "/opt/homebrew/bin/node",
                ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"],
                .claudeCode
            ),
            // Flags before the script must not consume the argument budget.
            (
                "/usr/local/bin/node",
                ["node", "--enable-source-maps", "/x/node_modules/claude-code/cli.js"],
                .claudeCode
            ),
            // `bun run <script>` puts the script one slot further out.
            ("/opt/homebrew/bin/bun", ["bun", "run", "/x/opencode-ai/index.ts"], .opencode),
            ("/opt/homebrew/bin/deno", ["deno", "/x/codex-cli/main.ts"], .codex)
        ]
        for (path, argv, expected) in hits {
            #expect(agent(path, argv) == expected, "should match: \(path) \(argv ?? [])")
        }

        let misses: [(String, [String]?, String)] = [
            ("/usr/bin/grep", nil, "an unrelated binary"),
            ("/opt/homebrew/bin/node", nil, "a Node process with no argv readable"),
            ("/opt/homebrew/bin/node", ["node"], "a Node process with no script argument"),
            (
                "/opt/homebrew/bin/node",
                ["node", "/Users/tester/my-claude-experiments/server.js"],
                "a PROJECT directory that merely contains the word — component "
                    + "equality is what keeps a folder name from pinning a Mac awake"
            ),
            (
                "/opt/homebrew/bin/node",
                ["node", "/x/claudette/index.js"],
                "a package whose name starts with the same letters"
            ),
            (
                "/usr/bin/vim",
                ["vim", "/Users/tester/.claude/settings.json"],
                "editing an agent's config is not running the agent"
            ),
            (
                "/opt/homebrew/bin/node",
                ["node", "a.js", "b.js", "/x/claude-code/cli.js"],
                "beyond the argument depth: the agent's own flags and the "
                    + "user's prompt text live out here, and `claude \"fix the "
                    + "codex bug\"` must not read as a Codex process"
            )
        ]
        for (path, argv, why) in misses {
            #expect(agent(path, argv) == nil, "must NOT match — \(why): \(path) \(argv ?? [])")
        }
    }

    /// The dot-directory `~/.claude` is not the executable `claude`. Worth its
    /// own line: it is on every Claude Code user's machine, it appears in the
    /// argv of anything that reads the config, and a substring matcher would
    /// have fired on all of it.
    @Test func theDotDirectoryIsNotTheBinary() {
        #expect(AgentProcessMatcher.agent(forScriptPath: "/Users/t/.claude/hooks/x.js") == nil)
        #expect(AgentProcessMatcher.agent(forScriptPath: "/Users/t/.claude") == nil)
    }
}

// MARK: - Scanning

@Suite struct ProcessScanning_ {

    private let now = Date(timeIntervalSince1970: 1_785_650_000)

    @Test func aScanCollapsesToThePresentAgents() {
        let enumerator = FakeProcessEnumerator(entries: [
            10: .init(path: "/opt/homebrew/bin/claude"),
            11: .init(path: "/opt/homebrew/bin/claude"),   // two windows, one agent
            12: .init(path: "/usr/bin/grep"),
            13: .init(path: "/opt/homebrew/bin/codex")
        ])
        let scanner = ProcessScanner(enumerator: enumerator, selfPID: 999)

        #expect(scanner.scan(now: now).count == 3)
        #expect(scanner.presentAgents(now: now) == [.claudeCode, .codex])
    }

    /// Every path that cannot produce an answer has to drop the pid. Reporting
    /// an agent we could not actually see is the one direction this scanner
    /// must never fail in: it is unbounded, and nothing downstream can
    /// contradict it.
    @Test func anUnreadableProcessIsNeverAnAgent() {
        // `executablePath` returning nil is what the real enumerator does for a
        // process that exited between the two syscalls, and for one belonging
        // to another user.
        let enumerator = FakeProcessEnumerator(entries: [:])
        let scanner = ProcessScanner(enumerator: enumerator, selfPID: 999)
        #expect(scanner.presentAgents(now: now).isEmpty)
    }

    /// "The keep-awake app kept itself awake" is a bug worth making
    /// structurally impossible rather than incidentally absent.
    @Test func ourOwnProcessIsNeverAnAgent() {
        let enumerator = FakeProcessEnumerator(entries: [
            42: .init(path: "/Applications/claude")
        ])
        #expect(ProcessScanner(enumerator: enumerator, selfPID: 42).presentAgents(now: now).isEmpty)
        #expect(ProcessScanner(enumerator: enumerator, selfPID: 1).presentAgents(now: now) == [.claudeCode])
    }

    /// Non-positive pids address a process group, never a process — the same
    /// rule `ProcessLiveness` and `ProcessActivitySampler` already follow.
    @Test func nonPositivePidsAreNeverProbed() {
        let enumerator = FakeProcessEnumerator(entries: [
            0: .init(path: "/opt/homebrew/bin/claude"),
            -1: .init(path: "/opt/homebrew/bin/claude")
        ])
        #expect(ProcessScanner(enumerator: enumerator, selfPID: 999).presentAgents(now: now).isEmpty)
    }

    /// argv costs a `sysctl(KERN_PROCARGS2)` per process. Reading it for every
    /// pid on the machine would pay that a thousand times to answer a question
    /// the executable path already answered.
    @Test func argvIsReadOnlyForInterpreters() {
        let enumerator = FakeProcessEnumerator(entries: [
            10: .init(path: "/opt/homebrew/bin/claude"),
            11: .init(path: "/usr/bin/grep"),
            12: .init(path: "/opt/homebrew/bin/node", arguments: ["node", "/x/claude-code/cli.js"])
        ])
        _ = ProcessScanner(enumerator: enumerator, selfPID: 999).scan(now: now)
        #expect(enumerator.argumentReads == [12])
    }
}

// MARK: - When it runs

@Suite struct ProcessScanGating {

    /// The default mode pays nothing. A running process is not a reason to
    /// hold there, so a scan could only feed the `.processOnly` precision row —
    /// not worth a permanent poll on every Mac.
    @Test func theDefaultModeNeverScans() {
        for precision in [DetectionPrecision.unavailable, .fileActivity, .hooks] {
            #expect(
                !ProcessScanner.shouldScan(
                    mode: .whileWorking,
                    precision: [.claudeCode: precision, .codex: precision, .opencode: precision]
                )
            )
        }
    }

    /// Plan 02 §3: 全员 `.hooks` 时 ProcessScanner 完全停转. Hooks already report
    /// every session including the idle one, so scanning would re-derive a fact
    /// the app has in a better form.
    @Test func fullHookCoverageStopsTheScanner() {
        let all: [AgentKind: DetectionPrecision] = [
            .claudeCode: .hooks, .codex: .hooks, .opencode: .hooks
        ]
        #expect(!ProcessScanner.shouldScan(mode: .whileRunning, precision: all))

        // `.hooksPartial` still delivers events session by session, so it still
        // answers the presence question and still stops the scan.
        var partial = all
        partial[.codex] = .hooksPartial
        #expect(!ProcessScanner.shouldScan(mode: .whileRunning, precision: partial))

        // One agent that cannot report sessions is enough to make a scan worth
        // running — the mode has to be true for that agent too.
        var degraded = all
        degraded[.codex] = .fileActivity
        #expect(ProcessScanner.shouldScan(mode: .whileRunning, precision: degraded))
    }

    /// An agent with no entry at all is an agent we know nothing about, which
    /// is exactly the case a process scan improves on. Read from an empty map,
    /// which is what a freshly-started root actually holds.
    @Test func anUnknownAgentIsWorthScanningFor() {
        #expect(ProcessScanner.shouldScan(mode: .whileRunning, precision: [:]))
    }
}

// MARK: - The real syscalls

@Suite struct DarwinProcessEnumeration {

    /// A libproc wrapper that compiles is not one that works. This runs against
    /// the machine's real process table — read-only, and asserting only on
    /// facts that are true of any running Mac plus one process we can name for
    /// certain: this test runner.
    ///
    /// What it actually pins is the buffer hygiene, verified by reverting each
    /// piece: dropping the `> 0` filter fails here, and so does the
    /// no-duplicates check. The bytes-vs-entries division (`proc_listpids`
    /// reports BYTES written, not entries) turns out to be defended by those
    /// two rather than by itself — reading four times too far lands in the
    /// zero-initialised slack, which the filter removes. That is worth knowing
    /// rather than assuming: the arithmetic is correct, but it is the padding
    /// filter that makes it safe.
    @Test func theEnumeratorReadsThisMachine() {
        let enumerator = DarwinProcessEnumerator()
        let pids = enumerator.listPIDs()

        #expect(pids.count > 10, "any running Mac has more processes than this")
        #expect(pids.allSatisfy { $0 > 0 }, "kernel padding must be filtered out")
        #expect(Set(pids).count == pids.count, "a pid cannot appear twice")
        #expect(pids.contains(getpid()), "we are ourselves a running process")
        #expect(pids.contains(1), "launchd is always pid 1")

        // The one path we can assert exactly: our own.
        let ourPath = enumerator.executablePath(for: getpid())
        #expect(ourPath != nil)
        #expect(ourPath?.hasPrefix("/") == true, "proc_pidpath returns an absolute path")

        // A pid that cannot exist must return nil rather than garbage — the
        // failure direction that matters, since a garbage path could match.
        #expect(enumerator.executablePath(for: pid_t.max) == nil)
        #expect(enumerator.executablePath(for: 0) == nil)
    }

    /// `KERN_PROCARGS2` parsing, against the only argv we know the shape of.
    /// argv[0] is conventionally the program itself, and the whole vector must
    /// stop at argc rather than running on into the environment — where a
    /// variable holding a path would read as an argument.
    @Test func theEnumeratorReadsItsOwnArguments() {
        let arguments = DarwinProcessEnumerator().arguments(for: getpid())
        #expect(arguments != nil, "we can always read our own argv")
        #expect(arguments?.isEmpty == false)
        // Everything CommandLine knows about must be in there, and nothing
        // beyond argc: an environment variable leaking in would show up as a
        // longer vector than the process actually has.
        #expect(arguments?.count == CommandLine.arguments.count)
        #expect(arguments?.first.map { ($0 as NSString).lastPathComponent }?.isEmpty == false)
    }

    /// The whole design rests on this being cheap enough to poll (plan 02 §3
    /// measured 2.69 ms for 1025 processes). If a full scan ever cost a
    /// noticeable fraction of the 5 s cadence, the gating above would stop
    /// being an optimisation and start being load-bearing.
    @Test func aFullScanIsCheap() {
        let scanner = ProcessScanner()
        let started = Date()
        _ = scanner.presentAgents(now: started)
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 1.0, "a full process scan took \(elapsed)s; the 5 s poll assumes milliseconds")
    }
}
