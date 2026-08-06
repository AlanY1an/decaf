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
//
// Concurrency invariant (the reason this file has a seam in it):
// the stream handle and the set of roots it covers are QUEUE-CONFINED to
// `queue`, which is also the stream's own FSEventStreamSetDispatchQueue. Two
// independent threads reach this type — the coordinator's actor calls
// `tickRootCheck()` from a cooperative-pool thread, and the FSEvents callback
// runs `handle(paths:flags:)` — and both can decide to tear the stream down
// (a root appearing/vanishing, a RootChanged event). Unsynchronised, both can
// pass the same `guard let stream` and call `FSEventStreamRelease` twice: an
// over-release, i.e. a crash, i.e. powerd reclaiming every assertion we hold.
// So every read and write of that state goes through `queue`, each such
// function opens with `assertOnQueue()`, and the handle itself releases at
// most once. Confining lifecycle to the stream's own delivery queue also
// means a callback can never be in flight while the stream is being released.

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
    private let startStream: FSEventStreamStarting

    /// Marks `queue` so `isOnQueue` can answer without a precondition trap;
    /// per instance, because two watchers may share a queue in tests.
    private let queueKey = DispatchSpecificKey<UInt8>()

    // MARK: Queue-confined stream state
    //
    // Touch these two ONLY from `queue` (see the concurrency invariant at the
    // top of this file). Every function that does starts with `assertOnQueue()`.

    /// The running stream, or nil when nothing is being watched.
    private var streamHandle: FSEventStreamHandle?
    /// Roots currently included in the running stream.
    private var streamedRoots: [Root] = []

    public init(
        roots: [Root] = FSEventsWatcher.defaultRoots(),
        latency: TimeInterval = DetectionDefaults.fseventsLatency,
        queue: DispatchQueue = DispatchQueue(label: "dev.caffeinate.app.fsevents", qos: .utility),
        fileManager: FileManager = .default,
        // Seam, defaulted to the real CoreServices stream. Tests substitute a
        // fake to drive the lifecycle (and assert its queue confinement)
        // without a kernel stream.
        startStream: @escaping FSEventStreamStarting = FSEventsWatcher.startCoreServicesStream
    ) {
        self.allRoots = roots
        self.latency = latency
        self.queue = queue
        self.fileManager = fileManager
        self.startStream = startStream
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        // Synchronous on purpose, and it must stay that way: an `async` here
        // would run after the object is gone, leaving the stream running and
        // its handle unreleased. `queue` is also the stream's delivery queue,
        // so this also drains any batch already in flight.
        runOnQueueSync { self.stopStreamOnQueue() }
        queue.setSpecific(key: queueKey, value: nil)
    }

    // MARK: Queue confinement helpers

    private var isOnQueue: Bool {
        DispatchQueue.getSpecific(key: queueKey) != nil
    }

    /// States the invariant in code: this function touches queue-confined state.
    private func assertOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
    }

    private func runOnQueueSync(_ body: () -> Void) {
        if isOnQueue {
            body()
        } else {
            queue.sync(execute: body)
        }
    }

    private func runOnQueueAsync(_ body: @escaping () -> Void) {
        if isOnQueue {
            body()
        } else {
            queue.async(execute: body)
        }
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
    ///
    /// Called from the coordinator's actor, i.e. NOT on `queue` — so the
    /// existence probe (which reads immutable state only) happens here and the
    /// stream reconciliation is handed to `queue`, where it cannot collide with
    /// an event callback doing the same thing.
    @discardableResult
    public func tickRootCheck() -> [AgentKind: Bool] {
        let existence = rootExistence()
        let present = allRoots.filter { existence[$0.agent] == true }
        runOnQueueAsync { [weak self] in
            self?.applyStreamedRootsOnQueue(present)
        }
        return existence
    }

    /// Stops watching entirely. Synchronous: after this returns the stream is
    /// released and no further callback can arrive.
    public func stop() {
        runOnQueueSync { self.stopStreamOnQueue() }
    }

    /// Test seam: delivers one event batch exactly as the C callback does —
    /// asynchronously, on the watcher's own queue.
    public func injectEventBatch(paths: [String], flags: [FSEventStreamEventFlags]) {
        runOnQueueAsync { [weak self] in
            self?.handle(paths: paths, flags: flags)
        }
    }

    /// Runs `body` after everything already queued on the watcher's queue has
    /// run. Test seam for the asynchronous stream reconciliation above.
    public func drain(_ body: @escaping () -> Void) {
        queue.async(execute: body)
    }

    // MARK: Stream plumbing (queue-confined)

    private func applyStreamedRootsOnQueue(_ present: [Root]) {
        assertOnQueue()
        guard present != streamedRoots else { return }
        stopStreamOnQueue()
        if !present.isEmpty {
            startStreamOnQueue(for: present)
        }
    }

    private func startStreamOnQueue(for roots: [Root]) {
        assertOnQueue()
        // One stream at a time, always: starting over a live handle would leak
        // it and lose the only reference that can release it.
        stopStreamOnQueue()
        guard let handle = startStream(
            roots.map(\.path),
            latency,
            queue,
            { [weak self] paths, flags in
                // Delivered on `queue` by construction.
                self?.handle(paths: paths, flags: flags)
            }
        ) else { return }
        streamHandle = handle
        streamedRoots = roots
    }

    private func stopStreamOnQueue() {
        assertOnQueue()
        // Clearing the reference BEFORE releasing is what makes a second caller
        // a no-op instead of a second release: there is exactly one owner of a
        // handle, and it hands ownership over here.
        guard let handle = streamHandle else { return }
        streamHandle = nil
        streamedRoots = []
        handle.stopAndRelease()
    }

    /// Called from the stream callback, on `queue`.
    private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        assertOnQueue()
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
            stopStreamOnQueue()
            if !remaining.isEmpty {
                startStreamOnQueue(for: remaining)
            }
            for agent in vanished {
                onRootVanished?(agent)
            }
        }
    }
}

// MARK: - Stream lifecycle seam

/// One running FSEvents stream. The watcher owns exactly one at a time and
/// releases it exactly once, from its own queue.
public protocol FSEventStreamHandle: AnyObject {
    /// Stops, invalidates and releases the underlying stream. Idempotent, but
    /// the watcher is structured so it is called once per handle anyway.
    func stopAndRelease()
}

/// Creates and starts a stream over `paths`, delivering each batch on `queue`.
/// Returns nil when the stream could not be created or started.
public typealias FSEventStreamStarting = (
    _ paths: [String],
    _ latency: TimeInterval,
    _ queue: DispatchQueue,
    _ onBatch: @escaping ([String], [FSEventStreamEventFlags]) -> Void
) -> FSEventStreamHandle?

extension FSEventsWatcher {

    /// The real CoreServices implementation (plan 02 §2 flags).
    public static func startCoreServicesStream(
        paths: [String],
        latency: TimeInterval,
        queue: DispatchQueue,
        onBatch: @escaping ([String], [FSEventStreamEventFlags]) -> Void
    ) -> FSEventStreamHandle? {
        CoreServicesStreamHandle(
            paths: paths,
            latency: latency,
            queue: queue,
            onBatch: onBatch
        )
    }
}

/// Retained by the stream context, so the callback never dereferences an object
/// that has already been deallocated (the previous design passed the watcher
/// itself unretained).
private final class FSEventsCallbackBox {
    let onBatch: ([String], [FSEventStreamEventFlags]) -> Void
    init(_ onBatch: @escaping ([String], [FSEventStreamEventFlags]) -> Void) {
        self.onBatch = onBatch
    }
}

private final class CoreServicesStreamHandle: FSEventStreamHandle {
    private let stream: FSEventStreamRef
    private let box: Unmanaged<FSEventsCallbackBox>
    /// Guards the release. The watcher already guarantees a single call; this
    /// is the belt to that pair of braces, because an over-release is a crash
    /// and a crash drops every power assertion the process holds.
    private var released = false

    init?(
        paths: [String],
        latency: TimeInterval,
        queue: DispatchQueue,
        onBatch: @escaping ([String], [FSEventStreamEventFlags]) -> Void
    ) {
        let box = Unmanaged.passRetained(FSEventsCallbackBox(onBatch))
        var context = FSEventStreamContext(
            version: 0,
            info: box.toOpaque(),
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
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            box.release()
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            box.release()
            return nil
        }
        self.stream = stream
        self.box = box
    }

    func stopAndRelease() {
        guard !released else { return }
        released = true
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        // Only after Invalidate, which is the point past which no further
        // callback can be delivered.
        box.release()
    }

    deinit {
        stopAndRelease()
    }
}

private let fsEventsCallback: FSEventStreamCallback = {
    _, info, numEvents, eventPaths, eventFlags, _ in
    guard let info else { return }
    let box = Unmanaged<FSEventsCallbackBox>.fromOpaque(info).takeUnretainedValue()
    // Created with kFSEventStreamCreateFlagUseCFTypes → eventPaths is a CFArray
    // of CFString.
    guard let paths = Unmanaged<CFArray>
        .fromOpaque(UnsafeRawPointer(eventPaths))
        .takeUnretainedValue() as? [String]
    else { return }
    let flags = Array(UnsafeBufferPointer(start: eventFlags, count: numEvents))
    box.onBatch(paths, flags)
}
