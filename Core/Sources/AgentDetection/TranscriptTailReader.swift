// TranscriptTailReader — incremental (tail) reads of agent transcript files
// (plan 08 §"性能:必须增量读取").
//
// Transcripts on a working machine reach ~30 MB across ~17 session files. A full
// re-parse on every FSEvents callback is not acceptable, so this type keeps a
// per-file byte offset and only ever hands the caller the bytes appended since
// the previous read.
//
// Discipline, in the order the plan states it:
//
// - `[URL: UInt64]` offsets; each read seeks to the stored offset and returns
//   only the COMPLETE lines found after it.
// - A half-written trailing line is kept in a per-file buffer and prefixed onto
//   the next read — never discarded as corruption (plan 08 §性能, bullet 3).
// - File shrank (rotation/truncation) or the inode changed (replaced) → offset
//   resets to 0 and the partial buffer is dropped.
// - Launch does not replay history: `startAtEnd` seeds a previously unseen file
//   at EOF, matching the `kFSEventStreamEventIdSinceNow` discipline of
//   FSEventsWatcher. See "New-file policy" below for the running-time choice.
// - Memory is bounded: the partial-line buffer is capped, and a pathological
//   line past the cap is dropped and the reader resynchronises at the next
//   newline rather than growing without limit.
//
// Privacy (plan 08 hard limit 3): this type is content-agnostic. It returns raw
// lines to its caller and never inspects, stores or LOGS their contents — field
// selection is the parser's job, and nothing here may print a transcript line.
//
// Not thread-safe by design: it is pure bookkeeping meant to live inside the
// caller's isolation domain (DetectionCoordinator is an actor).

import Darwin
import Foundation

// MARK: - Injected file seam

/// Identity + size of an open transcript file. `deviceID`/`inode` together
/// detect "same path, different file" (log rotation, session file replaced).
public struct TranscriptFileStat: Equatable, Sendable {
    public let size: UInt64
    public let deviceID: UInt64
    public let inode: UInt64

    public init(size: UInt64, deviceID: UInt64, inode: UInt64) {
        self.size = size
        self.deviceID = deviceID
        self.inode = inode
    }

    /// Whether this is the same underlying file as `other` (ignores size).
    public func isSameFile(as other: TranscriptFileStat) -> Bool {
        deviceID == other.deviceID && inode == other.inode
    }
}

/// The FileHandle-shaped seam the reader talks to. Tests inject temp files (or
/// a fake) so nothing ever reads the real ~/.claude.
public protocol TranscriptFileHandleProtocol: AnyObject {
    func fileStat() throws -> TranscriptFileStat
    func seek(toOffset offset: UInt64) throws
    /// Up to `count` bytes from the current position; empty Data means EOF.
    func read(upToCount count: Int) throws -> Data
    func close()
}

/// Opens transcript files for reading.
public protocol TranscriptFileOpening {
    /// Returns nil when the file is absent or unreadable — never throws, so a
    /// deleted transcript degrades to "no new lines" (plan 08 hard limit 1).
    func openForReading(_ url: URL) -> TranscriptFileHandleProtocol?
}

/// Production opener: a real `FileHandle` plus `fstat` for identity.
public struct POSIXTranscriptFileOpener: TranscriptFileOpening {
    public init() {}

    public func openForReading(_ url: URL) -> TranscriptFileHandleProtocol? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        return POSIXTranscriptFileHandle(handle: handle)
    }
}

private final class POSIXTranscriptFileHandle: TranscriptFileHandleProtocol {
    private let handle: FileHandle
    private var closed = false

    init(handle: FileHandle) {
        self.handle = handle
    }

    deinit {
        close()
    }

    func fileStat() throws -> TranscriptFileStat {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return TranscriptFileStat(
            size: UInt64(max(0, info.st_size)),
            deviceID: UInt64(bitPattern: Int64(info.st_dev)),
            inode: UInt64(info.st_ino)
        )
    }

    func seek(toOffset offset: UInt64) throws {
        try handle.seek(toOffset: offset)
    }

    func read(upToCount count: Int) throws -> Data {
        try handle.read(upToCount: count) ?? Data()
    }

    func close() {
        guard !closed else { return }
        closed = true
        try? handle.close()
    }
}

// MARK: - Reader

public final class TranscriptTailReader {

    /// Tuning knobs. Defaults are sized for the measured worst case on this
    /// machine (30.1 MB largest transcript, 17 session files).
    public enum Defaults {
        /// Per-`read` syscall chunk.
        public static let chunkBytes = 256 * 1024
        /// Hard ceiling on one buffered line. Real transcript lines are a few
        /// KB; 1 MiB is far past anything legitimate, so crossing it means the
        /// file is not what we think it is.
        public static let maxLineBytes = 1024 * 1024
        /// Ceiling on bytes consumed by a single call, so one enormous catch-up
        /// read cannot spike memory. The remainder is picked up by the next
        /// call (see `hasPendingBytes(at:)`).
        public static let maxBytesPerRead = 16 * 1024 * 1024
    }

    // MARK: Per-file bookkeeping

    private struct FileState {
        /// Bytes of this file already consumed (buffered partial included).
        var offset: UInt64 = 0
        /// Identity of the file the offset belongs to.
        var identity: TranscriptFileStat?
        /// Trailing bytes of an incomplete line, carried to the next read.
        var partial = Data()
        /// True after dropping an oversized line: swallow bytes until the next
        /// newline, then resume normally.
        var resynchronising = false
        /// The last read stopped on the byte budget rather than at EOF.
        var pendingBytes = false
    }

    private var states: [URL: FileState] = [:]

    private let opener: TranscriptFileOpening
    private let chunkBytes: Int
    private let maxLineBytes: Int
    private let maxBytesPerRead: Int

    public init(
        opener: TranscriptFileOpening = POSIXTranscriptFileOpener(),
        chunkBytes: Int = Defaults.chunkBytes,
        maxLineBytes: Int = Defaults.maxLineBytes,
        maxBytesPerRead: Int = Defaults.maxBytesPerRead
    ) {
        self.opener = opener
        self.chunkBytes = max(1, chunkBytes)
        self.maxLineBytes = max(1, maxLineBytes)
        self.maxBytesPerRead = max(1, maxBytesPerRead)
    }

    // MARK: Reading

    /// Returns the complete lines appended to `url` since the previous call.
    ///
    /// New-file policy — a deliberate split, because the two situations mean
    /// different things:
    ///
    /// - `startAtEnd: true` (app launch): the file already existed before we
    ///   were running, so its contents are history. Seeding the offset at EOF
    ///   mirrors `kFSEventStreamEventIdSinceNow`: we only care about "from now
    ///   on". Replaying it would resurrect long-expired wait signals — which
    ///   the 1-hour cap would clamp, but which would still be wrong.
    /// - `startAtEnd: false` (default, while running): a path we have never
    ///   seen just appeared, i.e. a session that started under our watch. Every
    ///   byte in it is new activity, so we read it from offset 0. Such a file
    ///   is by construction small — it was created moments ago.
    ///
    /// Once a file is tracked, `startAtEnd` no longer applies to it.
    ///
    /// Never throws: any IO or decoding trouble degrades to "no new lines"
    /// (plan 08 hard limit 1).
    @discardableResult
    public func readNewLines(at url: URL, startAtEnd: Bool = false) -> [String] {
        let key = url.standardizedFileURL

        guard let handle = opener.openForReading(url) else {
            // Could not open. Deliberately KEEP the bookkeeping.
            //
            // This path conflates two very different situations — the file was
            // deleted, and the open transiently failed (EMFILE under load, a
            // permissions blip, an atomic replace caught mid-rename). Dropping
            // the offset is only correct for the first, and is actively harmful
            // for the second: while running, an untracked path is read from
            // offset 0, so one failed open turns the next event into a full
            // re-read of a 30 MB transcript — exactly the full re-parse plan 08
            // §性能 forbids — and replays every still-live wait signal in its
            // history.
            //
            // Keeping the offset is safe for BOTH cases, because identity is
            // checked on the next successful open: same inode → resume where we
            // left off; a different file at the same path → the inode mismatch
            // below resets to 0 anyway. `forget(_:)` remains for callers that
            // truly know a file is finished with.
            return []
        }
        defer { handle.close() }

        guard let current = try? handle.fileStat() else { return [] }

        var state = states[key] ?? {
            var fresh = FileState()
            fresh.identity = current
            fresh.offset = startAtEnd ? current.size : 0
            return fresh
        }()

        // Replaced (different inode) or shrank (truncated/rotated) → restart.
        // Note the inherent tail limitation: a file truncated and regrown past
        // the old offset within one interval, keeping its inode, is invisible.
        if let known = state.identity, !known.isSameFile(as: current) {
            state = FileState(offset: 0, identity: current)
        } else if current.size < state.offset {
            state = FileState(offset: 0, identity: current)
        } else {
            state.identity = current
        }

        state.pendingBytes = false
        guard state.offset < current.size else {
            states[key] = state
            return []
        }

        guard (try? handle.seek(toOffset: state.offset)) != nil else {
            states[key] = state
            return []
        }

        var lines: [String] = []
        var consumed = 0
        let budget = min(maxBytesPerRead, Int(min(current.size - state.offset, UInt64(Int.max))))

        while consumed < budget {
            let want = min(chunkBytes, budget - consumed)
            guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else { break }
            consumed += chunk.count
            ingest(chunk, into: &state, lines: &lines)
        }

        state.offset &+= UInt64(consumed)
        state.pendingBytes = state.offset < current.size
        states[key] = state
        return lines
    }

    /// Launch helper: record each existing file's EOF without reading it, so a
    /// cold start never replays 30 MB of history.
    public func primeToEnd(_ urls: [URL]) {
        for url in urls {
            readNewLines(at: url, startAtEnd: true)
        }
    }

    // MARK: Introspection (also what the tests assert against)

    /// Current byte offset for `url`, or nil when the file is not tracked.
    public func offset(at url: URL) -> UInt64? {
        states[url.standardizedFileURL]?.offset
    }

    /// Whether the last read stopped on the per-call byte budget rather than at
    /// EOF; the caller may read again immediately to drain the remainder.
    public func hasPendingBytes(at url: URL) -> Bool {
        states[url.standardizedFileURL]?.pendingBytes ?? false
    }

    /// Bytes currently held back as an incomplete trailing line.
    public func bufferedPartialByteCount(at url: URL) -> Int {
        states[url.standardizedFileURL]?.partial.count ?? 0
    }

    /// True while swallowing the tail of an oversized line.
    public func isResynchronising(at url: URL) -> Bool {
        states[url.standardizedFileURL]?.resynchronising ?? false
    }

    /// Paths currently tracked.
    public var trackedFiles: [URL] {
        Array(states.keys)
    }

    /// Drops all bookkeeping for one file (e.g. its session ended).
    public func forget(_ url: URL) {
        states.removeValue(forKey: url.standardizedFileURL)
    }

    /// Drops all bookkeeping.
    public func reset() {
        states.removeAll()
    }

    // MARK: Line splitting

    private static let newline: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D

    /// Splits `chunk` into complete lines, carrying any trailing fragment in
    /// `state.partial` and enforcing the line-length ceiling.
    private func ingest(_ chunk: Data, into state: inout FileState, lines: inout [String]) {
        var cursor = chunk.startIndex

        while cursor < chunk.endIndex {
            let rest = chunk[cursor...]

            guard let newlineIndex = rest.firstIndex(of: Self.newline) else {
                // No newline in what remains.
                if state.resynchronising {
                    return  // still swallowing the oversized line
                }
                let fragment = rest
                if state.partial.count + fragment.count > maxLineBytes {
                    // Pathological line: drop what we have and swallow bytes
                    // until the next newline instead of growing the buffer.
                    state.partial.removeAll(keepingCapacity: false)
                    state.resynchronising = true
                    return
                }
                state.partial.append(contentsOf: fragment)
                return
            }

            if state.resynchronising {
                // The oversized line finally ends here; resume at the next byte.
                state.resynchronising = false
                cursor = chunk.index(after: newlineIndex)
                continue
            }

            let segment = chunk[cursor..<newlineIndex]
            if state.partial.count + segment.count > maxLineBytes {
                // Oversized, but we already have its terminator: drop the line
                // and carry straight on — no resync state needed.
                state.partial.removeAll(keepingCapacity: false)
            } else if state.partial.isEmpty {
                appendLine(from: segment, to: &lines)
            } else {
                state.partial.append(contentsOf: segment)
                appendLine(from: state.partial, to: &lines)
                state.partial.removeAll(keepingCapacity: true)
            }
            cursor = chunk.index(after: newlineIndex)
        }
    }

    /// Decodes one line, dropping a CRLF carriage return and blank lines.
    /// Invalid UTF-8 is replaced rather than rejected: the parser is the layer
    /// that decides a line is unusable, and it swallows what it cannot read.
    private func appendLine(from bytes: Data, to lines: inout [String]) {
        var slice = bytes[...]
        if let last = slice.last, last == Self.carriageReturn {
            slice = slice.dropLast()
        }
        guard !slice.isEmpty else { return }
        lines.append(String(decoding: slice, as: UTF8.self))
    }
}
