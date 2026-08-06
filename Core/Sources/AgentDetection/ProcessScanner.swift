// ProcessScanner — plan 02 §3's L3 process enumeration, built for
// `AgentHoldMode.whileRunning`.
//
// Why it had to exist before that mode could ship. "Keep this Mac awake
// whenever an agent is running" is a claim about a PROCESS. With hooks
// installed the claim is already answerable — a session exists, idle prompt
// included, and it disappears when the agent quits. Without hooks the only
// other signal in the app is L2 file activity, and a file write is an activity
// signal that says nothing about presence: it cannot tell an agent sitting
// idle at its prompt from one closed an hour ago. A user who picked the mode
// in that setup would have got `.whileWorking` behaviour under a label
// promising something else, which is the exact class of quiet lie the rest of
// today's work has been removing.
//
// So the mode needs a second way to answer "is it there", and the process
// table is it: a direct measurement rather than an inference. The cost is
// nil — a full 1025-process enumeration measures at 2.69 ms on this machine
// (plan 02 §3), so the 5 s poll below is free — and, unlike every inference in
// this app, the answer is falsifiable and self-limiting: the process is gone,
// the hold ends, on the next scan.
//
// Three structural rules it follows, all of them borrowed from
// `ProcessActivitySampler` next door:
//
// - the syscalls sit behind `ProcessEnumerating` with a fake, so the matching
//   rules are unit-testable without spawning anything;
// - the matcher is pure and total (`AgentProcessMatcher`), so the interesting
//   part — what counts as an agent — is tested as a table rather than against
//   whatever happens to be running on the machine;
// - a failed probe never becomes a positive. Every "cannot tell" path drops
//   the process. Under-reporting costs a hold this mode would have liked to
//   take; over-reporting keeps a Mac awake for something that is not an agent
//   at all, and that one is unbounded.

import Darwin
import Foundation

// MARK: - Sample

/// One matched agent process at one instant (plan 02 §3).
public struct AgentProcessSample: Equatable, Sendable {
    public var pid: pid_t
    public var agent: AgentKind
    /// The executable path that produced the match, kept for diagnostics — a
    /// false positive in `.whileRunning` keeps a Mac awake, and the first
    /// question will be "awake for what".
    public var executablePath: String
    public var sampledAt: Date

    public init(pid: pid_t, agent: AgentKind, executablePath: String, sampledAt: Date) {
        self.pid = pid
        self.agent = agent
        self.executablePath = executablePath
        self.sampledAt = sampledAt
    }
}

// MARK: - Seam

/// The IO seam over the process table (plan 02 §3; every IO seam in this
/// codebase is a protocol with a fake, cf. `PowerAsserting`,
/// `ProcessActivitySampling`).
public protocol ProcessEnumerating: Sendable {

    /// Every pid currently on the machine. Order is not significant.
    func listPIDs() -> [pid_t]

    /// Absolute executable path for `pid`, or nil when it cannot be read —
    /// the process exited between the two calls, or it belongs to another user
    /// and is not ours to inspect.
    func executablePath(for pid: pid_t) -> String?

    /// The process's argument vector, or nil when unavailable.
    ///
    /// Consulted only for interpreter executables (`node`, `bun`, `deno`),
    /// because that is the only case where the executable path does not name
    /// the program: an npm-installed Claude Code is `node …/cli.js`, and
    /// nothing about the basename `node` says which of the machine's dozen
    /// Node processes that is. Reading argv for every pid on the machine would
    /// pay `sysctl(KERN_PROCARGS2)` a thousand times to answer a question the
    /// executable path already answered.
    func arguments(for pid: pid_t) -> [String]?
}

// MARK: - Matching (pure)

/// What counts as an agent process, and — just as load-bearing — what does not.
///
/// Kept pure and separate from the enumeration so the rules can be tested as a
/// table. In `.whileRunning` a false positive is a Mac that does not sleep for
/// as long as the impostor runs, so the rules are deliberately narrow and the
/// interpreter path is the only fuzzy one.
public enum AgentProcessMatcher {

    /// Executable basenames that name an agent outright. The common install
    /// shapes (Homebrew, a native binary, `~/.claude/local/bin/claude`) all
    /// land here, and this path has no false-positive surface worth worrying
    /// about: the file is literally called `claude`.
    static let directNames: [String: AgentKind] = [
        "claude": .claudeCode,
        "codex": .codex,
        "opencode": .opencode
    ]

    /// Executables that run *other* programs, where the basename identifies the
    /// runtime and not the agent.
    static let interpreterNames: Set<String> = ["node", "bun", "deno"]

    /// Path components that identify an agent inside a script path.
    ///
    /// Component equality, not substring containment: `claude-code` matches the
    /// npm package directory `@anthropic-ai/claude-code`, while a project
    /// directory called `my-claude-experiments` does not match anything. A
    /// substring test would have matched both, and the second one is a Mac that
    /// never sleeps because of a folder name.
    static let scriptMarkers: [String: AgentKind] = [
        "claude": .claudeCode,
        "claude-code": .claudeCode,
        "codex": .codex,
        "codex-cli": .codex,
        "opencode": .opencode,
        "opencode-ai": .opencode
    ]

    /// How many leading arguments of an interpreter are allowed to name the
    /// program. `node <script>` needs one; `bun run <script>` needs two. Beyond
    /// that are the agent's own flags and the user's prompt text, which must
    /// never be matched against — `claude "fix the codex bug"` is a Claude Code
    /// process, and reading its prompt as evidence of a second agent would be
    /// both wrong and comic.
    static let interpreterArgumentDepth = 2

    /// The agent this executable path belongs to, or nil.
    ///
    /// `arguments` is a closure rather than a value so the caller pays for argv
    /// only on the interpreter branch that actually needs it.
    public static func agent(
        forExecutablePath path: String,
        arguments: () -> [String]?
    ) -> AgentKind? {
        let basename = (path as NSString).lastPathComponent
        if let direct = directNames[basename] { return direct }
        guard interpreterNames.contains(basename) else { return nil }
        guard let argv = arguments(), argv.count > 1 else { return nil }

        // argv[0] is the interpreter again; skip it. Flags are skipped rather
        // than counted, so `node --enable-source-maps …/cli.js` still resolves.
        var inspected = 0
        for argument in argv.dropFirst() {
            if argument.hasPrefix("-") { continue }
            if let agent = agent(forScriptPath: argument) { return agent }
            inspected += 1
            if inspected >= interpreterArgumentDepth { break }
        }
        return nil
    }

    /// The agent named by one script path, by exact path-component match.
    static func agent(forScriptPath path: String) -> AgentKind? {
        for component in path.split(separator: "/") {
            if let agent = scriptMarkers[String(component)] { return agent }
        }
        return nil
    }
}

// MARK: - Scanner

/// One full pass over the process table.
public protocol ProcessScanning: Sendable {
    func scan(now: Date) -> [AgentProcessSample]
}

public struct ProcessScanner: ProcessScanning {

    private let enumerator: any ProcessEnumerating
    /// Our own pid, never a match. Cheap insurance rather than a live concern:
    /// this app is called `Caffeinate` and its helper `caff-bridge`, so neither
    /// can match today — but "the keep-awake app kept itself awake" is a bug
    /// worth making structurally impossible rather than incidentally absent.
    private let selfPID: pid_t

    public init(
        enumerator: any ProcessEnumerating = DarwinProcessEnumerator(),
        selfPID: pid_t = getpid()
    ) {
        self.enumerator = enumerator
        self.selfPID = selfPID
    }

    public func scan(now: Date) -> [AgentProcessSample] {
        var samples: [AgentProcessSample] = []
        for pid in enumerator.listPIDs() {
            // A non-positive pid addresses a process group, never a process
            // (same rule as `ProcessLiveness` and `ProcessActivitySampler`).
            guard pid > 0, pid != selfPID else { continue }
            // nil means the process exited mid-scan or belongs to another user.
            // Either way it is not evidence of an agent, and inventing one from
            // a failed probe is the one direction this scanner must never fail
            // in.
            guard let path = enumerator.executablePath(for: pid) else { continue }
            guard let agent = AgentProcessMatcher.agent(
                forExecutablePath: path,
                arguments: { enumerator.arguments(for: pid) }
            ) else { continue }
            samples.append(
                AgentProcessSample(
                    pid: pid,
                    agent: agent,
                    executablePath: path,
                    sampledAt: now
                )
            )
        }
        return samples
    }
}

extension ProcessScanning {

    /// The form `DetectionCoordinator.noteAgentProcesses` consumes: which
    /// agents are present, with the pids collapsed away.
    ///
    /// The coordinator is deliberately told the COMPLETE result of one scan
    /// rather than an increment, which is what makes "the process disappeared"
    /// expressible: an agent absent from this set is absent from the machine,
    /// and its `.whileRunning` hold ends on that call rather than waiting out
    /// an idle window.
    public func presentAgents(now: Date) -> Set<AgentKind> {
        Set(scan(now: now).map(\.agent))
    }
}

// MARK: - When it is worth running

extension ProcessScanner {

    /// Whether a scan would tell us anything we do not already know.
    ///
    /// Two gates, and both are about not paying for nothing:
    ///
    /// - only in `.whileRunning`. In the default mode a running process is not
    ///   a reason to hold — that is the entire difference between the two
    ///   modes — so a scan could only feed the `.processOnly` precision row,
    ///   which is not worth a permanent poll on every Mac;
    /// - only while some agent is not delivering hook events (plan 02 §3: "全
    ///   员 `.hooks` 时 ProcessScanner 完全停转"). Hooks already report every
    ///   session including the idle one, so scanning would re-derive a fact the
    ///   app has in a better form.
    ///
    /// When this goes false the poll simply stops reporting, and the
    /// coordinator's `processScanStaleAfter` retires the last report on its own
    /// — so a mode switched back to `.whileWorking` cannot leave a stale
    /// presence hold standing.
    public static func shouldScan(
        mode: AgentHoldMode,
        precision: [AgentKind: DetectionPrecision]
    ) -> Bool {
        guard mode.holdsIdleAgents else { return false }
        // An agent with no precision entry at all is an agent we know nothing
        // about, which is precisely a case a process scan can improve on.
        return AgentKind.allCases.contains { (precision[$0] ?? .unavailable).deliversHookEvents == false }
    }
}

// MARK: - Real implementation

/// `proc_listpids` + `proc_pidpath` + `sysctl(KERN_PROCARGS2)`.
public struct DarwinProcessEnumerator: ProcessEnumerating {

    /// Headroom over the kernel's reported process count, so a machine that
    /// forks between the sizing call and the fetch is not silently truncated.
    private let slack: Int32

    public init(slack: Int32 = 64) {
        self.slack = max(0, slack)
    }

    public func listPIDs() -> [pid_t] {
        // Sizing call: byte length of the full table right now.
        let sizingBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard sizingBytes > 0 else { return [] }

        let stride = Int32(MemoryLayout<pid_t>.stride)
        let capacity = sizingBytes / stride + slack
        var pids = [pid_t](repeating: 0, count: Int(capacity))

        let writtenBytes = pids.withUnsafeMutableBufferPointer { buffer -> Int32 in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, capacity * stride)
        }
        guard writtenBytes > 0 else { return [] }

        // The kernel reports BYTES written, not entries; dividing is the whole
        // difference between reading the table and reading past it.
        let count = min(Int(writtenBytes / stride), pids.count)
        // Zero entries are padding in the kernel's buffer, not real processes.
        return pids.prefix(count).filter { $0 > 0 }
    }

    /// `PROC_PIDPATHINFO_MAXSIZE` is a C macro (`4 * MAXPATHLEN`) and macros do
    /// not survive the Swift importer, so the value is restated here.
    static let pathBufferSize = 4 * Int(MAXPATHLEN)

    public func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: DarwinProcessEnumerator.pathBufferSize)
        let length = proc_pidpath(pid, &buffer, UInt32(DarwinProcessEnumerator.pathBufferSize))
        // 0 is the documented failure return (ESRCH for an exited process,
        // EPERM for another user's). Both mean "no answer", never "no agent
        // here" — the caller drops the pid either way.
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    public func arguments(for pid: pid_t) -> [String]? {
        // KERN_PROCARGS2 layout: Int32 argc, the exec path (NUL-terminated),
        // NUL padding, then exactly argc NUL-terminated argv strings, then the
        // environment. Everything after argc is parsed by counting NULs, which
        // is why argc has to be read first and honoured exactly — running past
        // it walks into the environment, where a variable holding a path would
        // read as an argument.
        var argumentMaximum: Int32 = 0
        var argumentMaximumSize = MemoryLayout<Int32>.size
        var sizingName: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&sizingName, 2, &argumentMaximum, &argumentMaximumSize, nil, 0) == 0,
              argumentMaximum > 0
        else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(argumentMaximum))
        var size = Int(argumentMaximum)
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size
        else { return nil }

        var argumentCount: Int32 = 0
        withUnsafeMutableBytes(of: &argumentCount) { destination in
            buffer.withUnsafeBytes { source in
                destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[0..<4]))
            }
        }
        guard argumentCount > 0 else { return nil }

        // Walk past argc and the exec path, then past the NUL padding.
        var cursor = MemoryLayout<Int32>.size
        while cursor < size, buffer[cursor] != 0 { cursor += 1 }   // exec path
        while cursor < size, buffer[cursor] == 0 { cursor += 1 }   // padding

        var arguments: [String] = []
        var current: [CChar] = []
        while cursor < size, arguments.count < Int(argumentCount) {
            let byte = buffer[cursor]
            if byte == 0 {
                current.append(0)
                arguments.append(String(cString: current))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
            cursor += 1
        }
        return arguments.isEmpty ? nil : arguments
    }
}

// MARK: - Fake

/// Scripted `ProcessEnumerating` for unit tests (lives in the library target
/// alongside `FakeProcessActivitySampler`, so every suite shares one fake;
/// production code never instantiates it).
public final class FakeProcessEnumerator: ProcessEnumerating, @unchecked Sendable {

    public struct Entry: Sendable {
        public var path: String
        public var arguments: [String]?

        public init(path: String, arguments: [String]? = nil) {
            self.path = path
            self.arguments = arguments
        }
    }

    private let lock = NSLock()
    private var entries: [pid_t: Entry]
    /// Every pid whose argv was read, so a test can prove the interpreter
    /// branch is the only one paying for `KERN_PROCARGS2`.
    public private(set) var argumentReads: [pid_t] = []

    public init(entries: [pid_t: Entry] = [:]) {
        self.entries = entries
    }

    public func set(_ entries: [pid_t: Entry]) {
        lock.lock()
        defer { lock.unlock() }
        self.entries = entries
    }

    public func listPIDs() -> [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        return entries.keys.sorted()
    }

    public func executablePath(for pid: pid_t) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return entries[pid]?.path
    }

    public func arguments(for pid: pid_t) -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        argumentReads.append(pid)
        return entries[pid]?.arguments
    }
}
