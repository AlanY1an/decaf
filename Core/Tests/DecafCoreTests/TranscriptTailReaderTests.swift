// TranscriptTailReader tests (plan 08 §性能:必须增量读取).
//
// Every test builds its transcripts in a fresh temp directory — the real
// ~/.claude is never opened, read, or stat'ed (plan 08 constraint).

import Foundation
import Testing

@testable import AgentDetection

// MARK: - Temp-directory harness

/// A throwaway transcript directory. Nothing here touches ~/.claude.
private final class TempTranscriptDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("decaf-tail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    @discardableResult
    func write(_ name: String, _ contents: String) throws -> URL {
        let target = file(name)
        try Data(contents.utf8).write(to: target)
        return target
    }

    func append(_ name: String, _ contents: String) throws {
        let target = file(name)
        guard FileManager.default.fileExists(atPath: target.path) else {
            try write(name, contents)
            return
        }
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(contents.utf8))
    }

    func delete(_ name: String) throws {
        try FileManager.default.removeItem(at: file(name))
    }
}

/// A minimal JSONL record in the verified transcript shape. Only the reader is
/// under test here, so the contents just need to be distinguishable lines.
private func record(_ index: Int) -> String {
    #"{"type":"assistant","seq":\#(index)}"# + "\n"
}

// MARK: - Fake seam (proves the injection point, and lets us force IO failures)

private final class FakeFile {
    var bytes: Data
    var inode: UInt64
    init(bytes: Data, inode: UInt64) {
        self.bytes = bytes
        self.inode = inode
    }
}

private final class FakeOpener: TranscriptFileOpening {
    var files: [String: FakeFile] = [:]
    var openCount = 0

    func openForReading(_ url: URL) -> TranscriptFileHandleProtocol? {
        openCount += 1
        guard let file = files[url.path] else { return nil }
        return FakeHandle(file: file)
    }
}

private final class FakeHandle: TranscriptFileHandleProtocol {
    private let file: FakeFile
    private var position: UInt64 = 0

    init(file: FakeFile) {
        self.file = file
    }

    func fileStat() throws -> TranscriptFileStat {
        TranscriptFileStat(size: UInt64(file.bytes.count), deviceID: 1, inode: file.inode)
    }

    func seek(toOffset offset: UInt64) throws {
        position = offset
    }

    func read(upToCount count: Int) throws -> Data {
        let start = Int(min(position, UInt64(file.bytes.count)))
        let end = min(start + count, file.bytes.count)
        guard start < end else { return Data() }
        position = UInt64(end)
        return file.bytes.subdata(in: start..<end)
    }

    func close() {}
}

// MARK: - Tests

@Suite struct TranscriptTailReaderTests {

    // MARK: Incremental reads

    @Test func readsOnlyLinesAppendedSinceTheLastCall() throws {
        let dir = try TempTranscriptDir()
        let url = try dir.write("s.jsonl", record(1) + record(2))
        let reader = TranscriptTailReader()

        let first = reader.readNewLines(at: url)
        #expect(first.count == 2)
        #expect(first[0].contains("\"seq\":1"))
        #expect(first[1].contains("\"seq\":2"))

        // No change → nothing new, and the offset stays put.
        let offsetAfterFirst = reader.offset(at: url)
        #expect(reader.readNewLines(at: url).isEmpty)
        #expect(reader.offset(at: url) == offsetAfterFirst)

        try dir.append("s.jsonl", record(3))
        let second = reader.readNewLines(at: url)
        #expect(second == ["{\"type\":\"assistant\",\"seq\":3}"])
        #expect(reader.offset(at: url) ?? 0 > offsetAfterFirst ?? 0)
    }

    @Test func offsetTracksExactFileSizeAfterAFullRead() throws {
        let dir = try TempTranscriptDir()
        let body = record(1) + record(2) + record(3)
        let url = try dir.write("s.jsonl", body)
        let reader = TranscriptTailReader()

        #expect(reader.readNewLines(at: url).count == 3)
        #expect(reader.offset(at: url) == UInt64(body.utf8.count))
    }

    // MARK: Partial lines

    @Test func partialTrailingLineIsBufferedUntilItsNewlineArrives() throws {
        let dir = try TempTranscriptDir()
        // The writer got interrupted halfway through the second record.
        let url = try dir.write("s.jsonl", record(1) + #"{"type":"assistant","se"#)
        let reader = TranscriptTailReader()

        let first = reader.readNewLines(at: url)
        #expect(first.count == 1)
        #expect(first[0].contains("\"seq\":1"))
        // The half line is held, not returned and not discarded.
        #expect(reader.bufferedPartialByteCount(at: url) > 0)
        // ...but the offset has moved past it, so it is never re-read.
        #expect(reader.offset(at: url) == UInt64(try Data(contentsOf: url).count))

        try dir.append("s.jsonl", "q\":2}\n")
        let second = reader.readNewLines(at: url)
        #expect(second == ["{\"type\":\"assistant\",\"seq\":2}"])
        #expect(reader.bufferedPartialByteCount(at: url) == 0)
    }

    @Test func partialLineSplitAcrossManyTinyChunksReassembles() throws {
        let dir = try TempTranscriptDir()
        let url = dir.file("s.jsonl")
        // A 7-byte chunk size forces the split to land mid-line repeatedly.
        let reader = TranscriptTailReader(chunkBytes: 7)

        let line = #"{"type":"assistant","seq":1,"pad":"aaaaaaaaaaaaaaaaaaaa"}"#
        try dir.write("s.jsonl", line)
        #expect(reader.readNewLines(at: url).isEmpty)

        try dir.append("s.jsonl", "\n")
        #expect(reader.readNewLines(at: url) == [line])
    }

    @Test func blankLinesAndCarriageReturnsAreNormalisedAway() throws {
        let dir = try TempTranscriptDir()
        let url = try dir.write("s.jsonl", "\n" + record(1).dropLast() + "\r\n" + "\n" + record(2))
        let reader = TranscriptTailReader()

        let lines = reader.readNewLines(at: url)
        #expect(lines.count == 2)
        #expect(!lines.contains { $0.isEmpty })
        #expect(!lines.contains { $0.hasSuffix("\r") })
    }

    // MARK: Truncation / replacement / deletion

    @Test func truncatedFileResetsTheOffsetAndRereadsFromZero() throws {
        let dir = try TempTranscriptDir()
        let url = try dir.write("s.jsonl", record(1) + record(2) + record(3))
        let reader = TranscriptTailReader()
        #expect(reader.readNewLines(at: url).count == 3)

        // Rotation: same path, much shorter contents.
        try dir.write("s.jsonl", record(9))
        let afterTruncation = reader.readNewLines(at: url)
        #expect(afterTruncation.count == 1)
        #expect(afterTruncation[0].contains("\"seq\":9"))
        #expect(reader.offset(at: url) == UInt64(record(9).utf8.count))
    }

    @Test func fileReplacedWithSameSizeIsCaughtByInodeIdentity() throws {
        let dir = try TempTranscriptDir()
        let url = dir.file("s.jsonl")
        let reader = TranscriptTailReader()

        try dir.write("s.jsonl", record(1))
        #expect(reader.readNewLines(at: url).count == 1)

        // Replace via unlink + create: byte-identical length, new inode.
        try dir.delete("s.jsonl")
        try dir.write("s.jsonl", record(2))

        let lines = reader.readNewLines(at: url)
        #expect(lines.count == 1)
        #expect(lines[0].contains("\"seq\":2"))
    }

    @Test func inodeChangeIsDetectedEvenWhenTheReplacementIsLonger() {
        // Driven through the fake seam so the identity change is unambiguous.
        let opener = FakeOpener()
        let url = URL(fileURLWithPath: "/fake/s.jsonl")
        opener.files[url.path] = FakeFile(bytes: Data(record(1).utf8), inode: 100)
        let reader = TranscriptTailReader(opener: opener)

        #expect(reader.readNewLines(at: url).count == 1)

        opener.files[url.path] = FakeFile(bytes: Data((record(7) + record(8)).utf8), inode: 200)
        let lines = reader.readNewLines(at: url)
        #expect(lines.count == 2)
        #expect(lines[0].contains("\"seq\":7"))
        #expect(reader.offset(at: url) == UInt64((record(7) + record(8)).utf8.count))
    }

    @Test func deletedFileYieldsNoLinesAndTheReappearingFileIsReadFromTheTop() throws {
        let dir = try TempTranscriptDir()
        let url = try dir.write("s.jsonl", record(1))
        let reader = TranscriptTailReader()
        #expect(reader.readNewLines(at: url).count == 1)
        #expect(reader.offset(at: url) != nil)

        try dir.delete("s.jsonl")
        #expect(reader.readNewLines(at: url).isEmpty)

        // A file reappearing at the same path is a different file: the inode
        // check resets the offset, so it is read from the top.
        try dir.write("s.jsonl", record(5))
        let lines = reader.readNewLines(at: url)
        #expect(lines.count == 1)
        #expect(lines[0].contains("\"seq\":5"))
    }

    @Test func missingFileNeverThrowsAndLeavesOtherFilesAlone() throws {
        let dir = try TempTranscriptDir()
        let present = try dir.write("a.jsonl", record(1))
        let absent = dir.file("nope.jsonl")
        let reader = TranscriptTailReader()

        #expect(reader.readNewLines(at: present).count == 1)
        #expect(reader.readNewLines(at: absent).isEmpty)
        #expect(reader.offset(at: present) != nil)
    }

    // MARK: Multiple files

    @Test func offsetsAreTrackedPerFile() throws {
        let dir = try TempTranscriptDir()
        let a = try dir.write("a.jsonl", record(1))
        let b = try dir.write("b.jsonl", record(1) + record(2))
        let c = try dir.write("c.jsonl", "")
        let reader = TranscriptTailReader()

        #expect(reader.readNewLines(at: a).count == 1)
        #expect(reader.readNewLines(at: b).count == 2)
        #expect(reader.readNewLines(at: c).isEmpty)

        try dir.append("b.jsonl", record(3))
        #expect(reader.readNewLines(at: a).isEmpty)
        #expect(reader.readNewLines(at: b).count == 1)
        #expect(reader.readNewLines(at: c).isEmpty)

        #expect(reader.offset(at: a) == UInt64(record(1).utf8.count))
        #expect(reader.offset(at: b) == UInt64((record(1) + record(2) + record(3)).utf8.count))
        #expect(reader.trackedFiles.count == 3)

        reader.forget(b)
        #expect(reader.offset(at: b) == nil)
        reader.reset()
        #expect(reader.trackedFiles.isEmpty)
    }

    // MARK: startAtEnd (launch discipline)

    @Test func startAtEndSkipsHistoryAndPicksUpOnlySubsequentAppends() throws {
        let dir = try TempTranscriptDir()
        let history = record(1) + record(2) + record(3)
        let url = try dir.write("s.jsonl", history)
        let reader = TranscriptTailReader()

        // Launch: existing content is history, not activity.
        #expect(reader.readNewLines(at: url, startAtEnd: true).isEmpty)
        #expect(reader.offset(at: url) == UInt64(history.utf8.count))

        try dir.append("s.jsonl", record(4))
        let lines = reader.readNewLines(at: url)
        #expect(lines.count == 1)
        #expect(lines[0].contains("\"seq\":4"))
    }

    @Test func primeToEndSeedsEveryKnownFileWithoutReadingIt() throws {
        let dir = try TempTranscriptDir()
        let a = try dir.write("a.jsonl", record(1) + record(2))
        let b = try dir.write("b.jsonl", record(1))
        let reader = TranscriptTailReader()

        reader.primeToEnd([a, b])
        #expect(reader.offset(at: a) == UInt64((record(1) + record(2)).utf8.count))
        #expect(reader.offset(at: b) == UInt64(record(1).utf8.count))
        #expect(reader.readNewLines(at: a).isEmpty)
        #expect(reader.readNewLines(at: b).isEmpty)

        try dir.append("a.jsonl", record(3))
        #expect(reader.readNewLines(at: a).count == 1)
    }

    @Test func fileCreatedWhileRunningIsReadFromItsStart() throws {
        let dir = try TempTranscriptDir()
        let reader = TranscriptTailReader()
        // Launch primes the files that exist now...
        let existing = try dir.write("old.jsonl", record(1))
        reader.primeToEnd([existing])

        // ...a session that starts under our watch is new activity end to end.
        let fresh = try dir.write("new.jsonl", record(1) + record(2))
        let lines = reader.readNewLines(at: fresh)
        #expect(lines.count == 2)
    }

    @Test func startAtEndDoesNotApplyOnceAFileIsTracked() throws {
        let dir = try TempTranscriptDir()
        let url = try dir.write("s.jsonl", record(1))
        let reader = TranscriptTailReader()
        #expect(reader.readNewLines(at: url).count == 1)

        try dir.append("s.jsonl", record(2))
        // Even asked to start at the end, an already-tracked file reads its tail.
        #expect(reader.readNewLines(at: url, startAtEnd: true).count == 1)
    }

    // MARK: Bounded memory

    @Test func oversizedLineIsDroppedAndTheReaderResynchronisesAtTheNextNewline() throws {
        let dir = try TempTranscriptDir()
        let url = dir.file("s.jsonl")
        let cap = 4096
        let reader = TranscriptTailReader(chunkBytes: 512, maxLineBytes: cap)

        try dir.write("s.jsonl", record(1))
        #expect(reader.readNewLines(at: url).count == 1)

        // A single line an order of magnitude past the cap, delivered in pieces.
        let junk = String(repeating: "x", count: cap * 10)
        try dir.append("s.jsonl", junk)
        #expect(reader.readNewLines(at: url).isEmpty)
        // The buffer did not grow with it.
        #expect(reader.bufferedPartialByteCount(at: url) <= cap)
        #expect(reader.isResynchronising(at: url))

        // More of the same line, then its terminator and a healthy record.
        try dir.append("s.jsonl", junk + "\n" + record(2))
        let lines = reader.readNewLines(at: url)
        #expect(lines.count == 1)
        #expect(lines[0].contains("\"seq\":2"))
        #expect(!reader.isResynchronising(at: url))
        #expect(reader.bufferedPartialByteCount(at: url) == 0)
    }

    @Test func oversizedLineArrivingWholeIsDroppedWithoutStickyResync() throws {
        let dir = try TempTranscriptDir()
        let url = dir.file("s.jsonl")
        let cap = 2048
        let reader = TranscriptTailReader(maxLineBytes: cap)

        let junk = String(repeating: "y", count: cap * 4) + "\n"
        try dir.write("s.jsonl", record(1) + junk + record(2))

        let lines = reader.readNewLines(at: url)
        #expect(lines.count == 2)
        #expect(lines[0].contains("\"seq\":1"))
        #expect(lines[1].contains("\"seq\":2"))
        #expect(!reader.isResynchronising(at: url))
    }

    @Test func perCallByteBudgetIsRespectedAndTheRemainderIsFlaggedPending() throws {
        let dir = try TempTranscriptDir()
        let url = dir.file("s.jsonl")
        var body = ""
        for index in 1...100 { body += record(index) }
        try dir.write("s.jsonl", body)

        // Budget smaller than the file → partial drain, flagged as pending.
        let reader = TranscriptTailReader(chunkBytes: 64, maxBytesPerRead: 200)
        let first = reader.readNewLines(at: url)
        #expect(!first.isEmpty)
        #expect(first.count < 100)
        #expect(reader.hasPendingBytes(at: url))

        // Draining converges on the whole file with no line lost or duplicated.
        var all = first
        var guardCount = 0
        while reader.hasPendingBytes(at: url), guardCount < 1000 {
            all += reader.readNewLines(at: url)
            guardCount += 1
        }
        #expect(!reader.hasPendingBytes(at: url))
        #expect(all.count == 100)
        #expect(all[0].contains("\"seq\":1"))
        #expect(all[99].contains("\"seq\":100"))
        #expect(reader.offset(at: url) == UInt64(body.utf8.count))
    }

    // MARK: Robustness

    @Test func invalidUTF8DoesNotCrashOrStallTheStream() throws {
        let dir = try TempTranscriptDir()
        let url = dir.file("s.jsonl")
        var bytes = Data(record(1).utf8)
        bytes.append(contentsOf: [0xFF, 0xFE, 0xFD, 0x0A])
        bytes.append(contentsOf: Data(record(2).utf8))
        try bytes.write(to: url)

        let reader = TranscriptTailReader()
        let lines = reader.readNewLines(at: url)
        #expect(lines.count == 3)
        #expect(lines[2].contains("\"seq\":2"))
    }

    @Test func emptyFileIsTrackedAtOffsetZeroAndReadsNothing() throws {
        let dir = try TempTranscriptDir()
        let url = try dir.write("s.jsonl", "")
        let reader = TranscriptTailReader()

        #expect(reader.readNewLines(at: url).isEmpty)
        #expect(reader.offset(at: url) == 0)

        try dir.append("s.jsonl", record(1))
        #expect(reader.readNewLines(at: url).count == 1)
    }

    @Test func injectedSeamIsTheOnlyIOPathTaken() {
        // Proof that a caller can keep the reader entirely off the filesystem —
        // the mechanism that keeps ~/.claude out of the test suite.
        let opener = FakeOpener()
        let url = URL(fileURLWithPath: "/definitely/not/real/s.jsonl")
        opener.files[url.path] = FakeFile(bytes: Data(record(1).utf8), inode: 42)
        let reader = TranscriptTailReader(opener: opener)

        #expect(reader.readNewLines(at: url).count == 1)
        #expect(opener.openCount == 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Performance

    @Test func thirtyMegabyteTranscriptWithOneAppendedLineTailReadsFast() throws {
        let dir = try TempTranscriptDir()
        let url = dir.file("big.jsonl")

        // Build ~30 MB, matching the largest transcript measured on this machine.
        let filler = #"{"type":"assistant","message":{"content":[{"type":"text"}]},"pad":"#
            + "\"" + String(repeating: "z", count: 900) + "\"}\n"
        let block = Data(String(repeating: filler, count: 1000).utf8)  // ~1 MB
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let writer = try FileHandle(forWritingTo: url)
        for _ in 0..<31 { try writer.write(contentsOf: block) }
        try writer.close()

        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        #expect(size > 30_000_000)

        // Launch discipline: seed at EOF without reading the 30 MB.
        let reader = TranscriptTailReader()
        let primeStart = DispatchTime.now().uptimeNanoseconds
        reader.primeToEnd([url])
        let primeMs = Double(DispatchTime.now().uptimeNanoseconds - primeStart) / 1_000_000
        #expect(reader.offset(at: url) == UInt64(size))
        #expect(primeMs < 50, "priming a 30 MB transcript took \(primeMs) ms")

        // One appended record: the tail read must not touch the other 30 MB.
        try dir.append("big.jsonl", record(1))
        let readStart = DispatchTime.now().uptimeNanoseconds
        let lines = reader.readNewLines(at: url)
        let readMs = Double(DispatchTime.now().uptimeNanoseconds - readStart) / 1_000_000
        #expect(lines.count == 1)
        #expect(lines[0].contains("\"seq\":1"))
        #expect(readMs < 50, "tail-reading one appended line took \(readMs) ms")
    }
}
