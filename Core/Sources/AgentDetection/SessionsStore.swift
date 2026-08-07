// SessionsStore — sessions.json persistence with bootTime guard (plan 02 §1.2).
//
// Registry changes are debounce-written (≤1 write/second) to
// ~/Library/Application Support/Decaf/sessions.json as
// `{ bootTime, sessions: [AgentSession] }`.
//
// On app launch the file is read back; if its `bootTime` (sysctl kern.boottime)
// differs from the current boot, the whole snapshot is discarded — after a
// reboot every persisted pid is invalid, and restoring them would resurrect
// ghost sessions the PPID sweep cannot reliably kill (pid reuse). When boot
// times match, the caller restores the sessions and must run a sweep
// immediately: app crash + relaunch keeps working sessions alive without
// picking up ghosts.

import Darwin
import Foundation

/// On-disk shape of sessions.json.
public struct SessionsSnapshot: Codable, Equatable, Sendable {
    /// `sysctl kern.boottime` seconds at write time.
    public var bootTime: TimeInterval
    public var sessions: [AgentSession]

    public init(bootTime: TimeInterval, sessions: [AgentSession]) {
        self.bootTime = bootTime
        self.sessions = sessions
    }
}

public final class SessionsStore {

    public let fileURL: URL

    private let bootTimeProvider: () -> TimeInterval
    private let debounceInterval: TimeInterval
    private let queue = DispatchQueue(label: "io.github.alany1an.decaf.sessions-store", qos: .utility)
    private var pendingSessions: [AgentSession]?
    private var flushScheduled = false

    public init(
        fileURL: URL? = nil,
        debounceInterval: TimeInterval = 1.0,
        bootTimeProvider: @escaping () -> TimeInterval = SessionsStore.systemBootTime
    ) {
        self.fileURL = fileURL ?? SessionsStore.defaultFileURL()
        self.debounceInterval = max(0, debounceInterval)
        self.bootTimeProvider = bootTimeProvider
    }

    /// ~/Library/Application Support/Decaf/sessions.json
    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Decaf", isDirectory: true)
            .appendingPathComponent("sessions.json", isDirectory: false)
    }

    /// Current boot instant via `sysctl kern.boottime`, whole seconds.
    ///
    /// Whole-second comparison keeps the guard stable against sub-second
    /// jitter while still changing on every actual reboot.
    public static func systemBootTime() -> TimeInterval {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return 0 }
        return TimeInterval(tv.tv_sec)
    }

    // MARK: Load

    /// Reads sessions back. Returns [] when the file is missing, unreadable,
    /// malformed, or written under a different boot (bootTime guard).
    public func load() -> [AgentSession] {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(SessionsSnapshot.self, from: data)
        else { return [] }
        guard snapshot.bootTime == bootTimeProvider() else { return [] }
        return snapshot.sessions
    }

    // MARK: Save

    /// Debounced save: coalesces bursts so the file is written at most once
    /// per `debounceInterval` (plan 02 §1.2: ≤1 write/second).
    public func scheduleSave(_ sessions: [AgentSession]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingSessions = sessions
            guard !self.flushScheduled else { return }
            self.flushScheduled = true
            self.queue.asyncAfter(deadline: .now() + self.debounceInterval) { [weak self] in
                self?.flushLocked()
            }
        }
    }

    /// Synchronous write, bypassing the debounce (shutdown path and tests).
    public func saveNow(_ sessions: [AgentSession]) {
        queue.sync {
            self.pendingSessions = sessions
            self.flushLocked()
        }
    }

    /// Flushes any pending debounced write synchronously.
    public func flush() {
        queue.sync {
            self.flushLocked()
        }
    }

    /// Must be called on `queue`.
    private func flushLocked() {
        flushScheduled = false
        guard let sessions = pendingSessions else { return }
        pendingSessions = nil

        let snapshot = SessionsSnapshot(bootTime: bootTimeProvider(), sessions: sessions)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence is best-effort: losing a snapshot only costs
            // crash-recovery fidelity, never correctness of live detection.
        }
    }
}
