// UsageStore — usage.json persistence (plan 09 M1).
//
// Debounce-written like SessionsStore. No bootTime guard: token history is
// wall-clock data and survives reboots by design. Dedup keys are NOT stored
// (see UsageLedger); the upstream reader's offsets (M3) own replay safety.

import Foundation

public final class UsageStore {

    public let fileURL: URL

    private let debounceInterval: TimeInterval
    private let queue = DispatchQueue(label: "io.github.alany1an.decaf.usage-store", qos: .utility)
    private var pendingState: UsageLedgerState?
    private var flushScheduled = false

    public init(fileURL: URL? = nil, debounceInterval: TimeInterval = 5.0) {
        self.fileURL = fileURL ?? UsageStore.defaultFileURL()
        self.debounceInterval = max(0, debounceInterval)
    }

    /// ~/Library/Application Support/Decaf/usage.json
    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Decaf", isDirectory: true)
            .appendingPathComponent("usage.json", isDirectory: false)
    }

    /// nil when missing, unreadable, or malformed — the ledger then starts
    /// empty and rebuilds from live transcripts.
    public func load() -> UsageLedgerState? {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? Self.decoder().decode(UsageLedgerState.self, from: data)
        else { return nil }
        return state
    }

    public func save(_ state: UsageLedgerState) {
        queue.async {
            self.pendingState = state
            guard !self.flushScheduled else { return }
            self.flushScheduled = true
            self.queue.asyncAfter(deadline: .now() + self.debounceInterval) {
                self.writePending()
            }
        }
    }

    /// Synchronous drain for shutdown and tests.
    public func flush() {
        queue.sync { self.writePending() }
    }

    private func writePending() {
        flushScheduled = false
        guard let state = pendingState else { return }
        pendingState = nil
        guard let data = try? Self.encoder().encode(state) else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
