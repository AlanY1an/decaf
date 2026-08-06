// FSEventsWatcher — L2 file-activity fallback (plan 02 §2).
//
// Install-free, lossy, agent-granularity (not session-granularity) detection:
// one recursive FSEventStream over each agent's transcript root, filtered to
// meaningful activity paths, feeding `lastActivityAt[agent]` refreshes into the
// coordinator. The idle-window hold decision itself lives in
// DetectionCoordinator (plan 02 step 6); this type only produces signals.
//
// Watch configuration (all plan-pinned):
// - root: ~/.claude (NOT ~/.claude/projects — that dir does not exist before
//   claude has ever run; root existence is re-checked on every tick and the
//   stream is (re)started once it appears).
// - latency 1.5 s; FileEvents | NoDefer | WatchRoot (+ UseCFTypes for Swift).
// - only paths under <root>/projects/ count as activity, and settings.json is
//   excluded everywhere (the installer writing our own hooks config must never
//   trigger a hold).
// - MustScanSubDirs (incl. KernelDropped/UserDropped coalescing) cannot be
//   attributed to a file → counts as one activity signal for the owning root;
//   we deliberately do NOT rescan (this layer only needs "did something move").
// - RootChanged → stop watching that root, fall back to tick existence checks.
// - EventIdsWrapped → ignored.

import CoreServices
import Foundation
import HookWire

public final class FSEventsWatcher {

    // MARK: Roots

    /// One watched agent root.
    public struct Root: Equatable, Sendable {
        public let agent: AgentKind
        /// Absolute watch root, e.g. /Users/me/.claude (no trailing slash).
        public let path: String
        /// Only paths under this prefix count as activity, e.g.
        /// /Users/me/.claude/projects/
        public let activityPrefix: String

        /// Both strings are normalised with the SAME rule, and the prefix is
        /// re-anchored on the standardised root rather than standardised on its
        /// own.
        ///
        /// `standardizingPath` rewrites `/private/tmp/x` to `/tmp/x` — but only
        /// when the path exists. Standardising `path` and `activityPrefix`
        /// independently can therefore leave them in two different spellings of
        /// the same directory (typically because one exists and the other does
        /// not yet), and `classify` would then reject every event under the
        /// root as `.ignored`: no L2 activity, no transcript tail-read, no wait
        /// signals — silently. `~/.claude` on a normal machine standardises to
        /// itself, so this only bites on symlinked or `/private`-rooted homes,
        /// which is exactly where the acceptance harness runs.
        public init(agent: AgentKind, path: String, activityPrefix: String) {
            self.agent = agent
            let root = (path as NSString).standardizingPath
            self.path = root
            if activityPrefix.hasPrefix(path) {
                self.activityPrefix = root + activityPrefix.dropFirst(path.count)
            } else {
                // Not actually under `path` — standardise it on its own and
                // keep the trailing slash the prefix test relies on.
                let standardized = (activityPrefix as NSString).standardizingPath
                self.activityPrefix = standardized.hasSuffix("/") ? standardized : standardized + "/"
            }
        }

        /// The claude root: ~/.claude with activity under projects/.
        public static func claude(home: String = NSHomeDirectory()) -> Root {
            let root = (home as NSString).appendingPathComponent(".claude")
            return Root(
                agent: .claudeCode,
                path: root,
                activityPrefix: (root as NSString).appendingPathComponent("projects") + "/"
            )
        }
    }

    /// MVP watches claude only; V1.x appends ~/.codex/sessions and the
    /// opencode log root to the same (single) stream.
    public static func defaultRoots() -> [Root] {
        [.claude()]
    }

    // MARK: Pure classification (unit-testable without FSEvents)

    public enum Classification: Equatable {
        /// Meaningful file activity for this agent.
        case activity(AgentKind)
        /// The watch root itself moved/vanished; stop the stream for it.
        case rootChanged(AgentKind)
        case ignored
    }

    /// Classifies one FSEvents callback entry (plan 02 §2 filtering rules).
    public static func classify(
        path: String,
        flags: FSEventStreamEventFlags,
        roots: [Root]
    ) -> Classification {
        let normalized = (path as NSString).standardizingPath
        guard let root = owningRoot(of: normalized, in: roots) else { return .ignored }

        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
            return .rootChanged(root.agent)
        }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
            // Queue overflow (KernelDropped/UserDropped variants set this too):
            // cannot attribute to a file — count as one activity signal for the
            // owning agent, without rescanning anything.
            return .activity(root.agent)
        }
        // Plain file event: must fall under the activity prefix, and never
        // settings.json (our installer's own writes must not hold the Mac).
        guard normalized.hasPrefix(root.activityPrefix) || normalized + "/" == root.activityPrefix else {
            return .ignored
        }
        guard (normalized as NSString).lastPathComponent != "settings.json" else {
            return .ignored
        }
        return .activity(root.agent)
    }

    private static func owningRoot(of path: String, in roots: [Root]) -> Root? {
        roots.first { path == $0.path || path.hasPrefix($0.path + "/") }
    }

    // MARK: Transcript paths (plan 08 — the tail reader needs WHICH file moved)

    /// Transcript-file suffix. One JSONL file per session under
    /// `<root>/projects/<slug>/<session-uuid>.jsonl`.
    public static let transcriptExtension = "jsonl"

    /// The transcript file this event path denotes, or nil when the path is not
    /// a transcript (a directory, a lock file, a `settings.json`, an event that
    /// could not be attributed to a file at all).
    ///
    /// Deliberately narrower than `classify`: an unattributable overflow event
    /// still counts as L2 activity, but there is no file to tail-read, so wait
    /// signals simply wait for the next real write. Guessing (rescanning the
    /// tree) is what plan 02 §2 says not to do.
    public static func transcriptURL(path: String, roots: [Root]) -> URL? {
        let normalized = (path as NSString).standardizingPath
        guard case .activity = classify(path: path, flags: 0, roots: roots),
              (normalized as NSString).pathExtension == transcriptExtension
        else { return nil }
        return URL(fileURLWithPath: normalized)
    }

    /// Every transcript file that exists under the configured roots right now.
    ///
    /// Used once, at launch, to seed the tail reader's offsets at EOF: history
    /// written before we were running is history (same "since now" discipline
    /// as `kFSEventStreamEventIdSinceNow`).
    public func existingTranscriptFiles() -> [AgentKind: [URL]] {
        var result: [AgentKind: [URL]] = [:]
        for root in allRoots {
            let projects = URL(fileURLWithPath: root.activityPrefix, isDirectory: true)
            guard let walker = fileManager.enumerator(
                at: projects,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            var files: [URL] = []
            for case let url as URL in walker
            where url.pathExtension == Self.transcriptExtension {
                files.append(url)
            }
            if !files.isEmpty {
                result[root.agent, default: []].append(contentsOf: files)
            }
        }
        return result
    }

    // MARK: Live watcher

    /// Called (on `queue`) for each activity signal.
    public var onActivity: ((AgentKind, Date) -> Void)?
    /// Called (on `queue`) with the transcript files touched by an event batch,
    /// so the coordinator can tail-read them for wait signals (plan 08).
    /// Always paired with an `onActivity` call for the same agent; a batch that
    /// named no file (queue overflow) fires only the latter.
    public var onTranscriptActivity: ((AgentKind, [URL], Date) -> Void)?
    /// Called (on `queue`) when a watched root vanished (RootChanged).
    public var onRootVanished: ((AgentKind) -> Void)?

    private let allRoots: [Root]
    private let latency: TimeInterval
    private let queue: DispatchQueue
    private let fileManager: FileManager

    private var stream: FSEventStreamRef?
    /// Roots currently included in the running stream.
    private var streamedRoots: [Root] = []

    public init(
        roots: [Root] = FSEventsWatcher.defaultRoots(),
        latency: TimeInterval = DetectionDefaults.fseventsLatency,
        queue: DispatchQueue = DispatchQueue(label: "dev.caffeinate.app.fsevents", qos: .utility),
        fileManager: FileManager = .default
    ) {
        self.allRoots = roots
        self.latency = latency
        self.queue = queue
        self.fileManager = fileManager
    }

    deinit {
        stopStream()
    }

    /// Existence check for one agent's watch root (drives §4 precision).
    public func rootExists(for agent: AgentKind) -> Bool {
        guard let root = allRoots.first(where: { $0.agent == agent }) else { return false }
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Per-agent root existence for every configured root.
    public func rootExistence() -> [AgentKind: Bool] {
        var result: [AgentKind: Bool] = [:]
        for root in allRoots {
            var isDir: ObjCBool = false
            result[root.agent] =
                fileManager.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
        }
        return result
    }

    /// Tick entry point (plan 02 §2): checks which roots exist and (re)starts
    /// the single multi-path stream when the existing-root set changed.
    /// Returns the current per-agent existence map.
    @discardableResult
    public func tickRootCheck() -> [AgentKind: Bool] {
        let existence = rootExistence()
        let present = allRoots.filter { existence[$0.agent] == true }
        if present != streamedRoots {
            stopStream()
            if !present.isEmpty {
                startStream(for: present)
            }
        }
        return existence
    }

    /// Stops watching entirely.
    public func stop() {
        stopStream()
    }

    // MARK: Stream plumbing

    private func startStream(for roots: [Root]) {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsCallback,
            &context,
            roots.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
        self.streamedRoots = roots
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        self.streamedRoots = []
    }

    /// Called from the C callback on `queue`.
    fileprivate func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        var vanished: Set<AgentKind> = []
        var active: Set<AgentKind> = []
        // Per agent, de-duplicated but order-preserving: one FSEvents batch
        // routinely names the same transcript several times, and tail-reading
        // it once is enough.
        var transcripts: [AgentKind: [URL]] = [:]
        var seenTranscripts: Set<URL> = []
        for (index, path) in paths.enumerated() {
            let eventFlags = index < flags.count ? flags[index] : 0
            // EventIdsWrapped: bookkeeping only, ignore (plan 02 §2).
            if eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped) != 0 {
                continue
            }
            switch FSEventsWatcher.classify(path: path, flags: eventFlags, roots: streamedRoots) {
            case .activity(let agent):
                active.insert(agent)
                if let url = FSEventsWatcher.transcriptURL(path: path, roots: streamedRoots),
                   seenTranscripts.insert(url).inserted {
                    transcripts[agent, default: []].append(url)
                }
            case .rootChanged(let agent):
                vanished.insert(agent)
            case .ignored:
                break
            }
        }
        let now = Date()
        for agent in active {
            onActivity?(agent, now)
            if let urls = transcripts[agent] {
                onTranscriptActivity?(agent, urls, now)
            }
        }
        if !vanished.isEmpty {
            // Drop vanished roots from the stream; the tick existence check
            // will restart them if/when they come back.
            let remaining = streamedRoots.filter { !vanished.contains($0.agent) }
            stopStream()
            if !remaining.isEmpty {
                startStream(for: remaining)
            }
            for agent in vanished {
                onRootVanished?(agent)
            }
        }
    }
}

private let fsEventsCallback: FSEventStreamCallback = {
    _, info, numEvents, eventPaths, eventFlags, _ in
    guard let info else { return }
    let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
    // Created with kFSEventStreamCreateFlagUseCFTypes → eventPaths is a CFArray
    // of CFString.
    guard let paths = Unmanaged<CFArray>
        .fromOpaque(UnsafeRawPointer(eventPaths))
        .takeUnretainedValue() as? [String]
    else { return }
    let flags = Array(UnsafeBufferPointer(start: eventFlags, count: numEvents))
    watcher.handle(paths: paths, flags: flags)
}
