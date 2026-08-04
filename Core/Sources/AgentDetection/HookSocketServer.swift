// HookSocketServer — L1 UNIX-domain-socket listener (plan 02 §1.4, step 4).
//
// Receives single-line WireEvent JSON frames from caff-bridge over
// ~/Library/Application Support/Caffeinate/agent.sock and feeds them into an
// AsyncStream consumed by DetectionCoordinator. Design decisions (plan 02 §1.4):
// - BSD sockets + DispatchSource, not Network.framework (UDS support there has
//   historical quirks; a few dozen lines of POSIX are more controllable and
//   easier to integration-test).
// - One short-lived connection per event, fire-and-forget, no reply: read to
//   "\n" (or EOF, or the 4 KB cap), parse, close.
// - Undecodable lines are dropped with a debug log and never affect other
//   connections. Unknown event names / protocol versions / agents decode fine
//   and are passed through untouched — the bridge and this server are dumb
//   pipes; semantic normalization happens downstream in SessionRegistry.
// - chmod 0600 after bind. Same-uid processes can still forge events; a local
//   same-user attacker can do far worse than keeping the Mac awake, so no
//   further hardening (plan 02 §1.4).
// - The socket doubles as the single-instance lock: bind failure while a live
//   listener answers is surfaced as a typed error; the app shell (plan 04
//   step 1, review decision R11) turns it into "Caffeinate is already
//   running" and exits. A leftover socket file nobody answers (crash residue)
//   is unlinked and rebound.
// - `rebuild()` + `socketFilePresent` support the coordinator's watchdog
//   (plan 02 §1.6): stat check each tick, unlink → bind → listen on failure.

import Foundation
import HookWire
import os

/// Typed failures from `HookSocketServer.start()` / `rebuild()`.
public enum HookSocketServerError: Error, Equatable, Sendable {
    /// The socket path exceeds sun_path's 104-byte limit (plan 02 risk R7):
    /// the caller must disable L1 and surface the degradation.
    case socketPathTooLong(path: String)
    /// bind failed and a live listener answered the path: another Caffeinate
    /// instance is running (plan 02 §1.4 single-instance lock; the app shell
    /// owns the user-facing behavior per review decision R11).
    case anotherInstanceRunning(path: String)
    /// Unexpected system-call failure, with the failing call and its errno.
    case systemCallFailed(operation: String, errno: Int32)
}

public final class HookSocketServer: @unchecked Sendable {
    /// Per-connection read cap (plan 02 §1.4: parse at "\n" or 4 KB).
    public static let maxLineBytes = 4096

    /// ~/Library/Application Support/Caffeinate/agent.sock (plan 02 §1.4).
    public static var defaultSocketPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/Caffeinate/agent.sock")
    }

    /// Decoded frames, in arrival order. Single consumer: DetectionCoordinator.
    public let events: AsyncStream<WireEvent>

    public let socketPath: String

    private let continuation: AsyncStream<WireEvent>.Continuation
    private let queue = DispatchQueue(label: "dev.caffeinate.app.hook-socket-server")
    private let logger = Logger(subsystem: "dev.caffeinate.app", category: "HookSocketServer")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]

    private final class Connection {
        let fd: Int32
        let source: DispatchSourceRead
        var buffer = Data()

        init(fd: Int32, source: DispatchSourceRead) {
            self.fd = fd
            self.source = source
        }
    }

    public init(socketPath: String = HookSocketServer.defaultSocketPath) {
        self.socketPath = socketPath
        var streamContinuation: AsyncStream<WireEvent>.Continuation!
        self.events = AsyncStream { streamContinuation = $0 }
        self.continuation = streamContinuation
    }

    // MARK: - Lifecycle

    /// Binds, chmods 0600, listens, and starts the accept loop.
    /// Throws `HookSocketServerError`; `.anotherInstanceRunning` carries the
    /// single-instance semantics for the app shell (R11).
    public func start() throws {
        try queue.sync { try startLocked() }
    }

    /// Full shutdown: closes everything, unlinks the socket file, and finishes
    /// the event stream. A stopped server cannot be restarted — use `rebuild()`
    /// for watchdog recovery, which keeps the stream alive.
    public func stop() {
        queue.sync { tearDownLocked() }
        continuation.finish()
    }

    /// Watchdog recovery (plan 02 §1.6): unlink → bind → listen without
    /// terminating the event stream. Safe to call whether or not the listener
    /// is currently up.
    public func rebuild() throws {
        try queue.sync {
            tearDownLocked()
            try startLocked()
        }
    }

    /// Tick-time stat check (plan 02 §1.6): true while the bound socket file
    /// still exists on disk as a socket. The coordinator calls `rebuild()`
    /// when this turns false.
    public var socketFilePresent: Bool {
        var status = stat()
        guard stat(socketPath, &status) == 0 else { return false }
        return (status.st_mode & S_IFMT) == S_IFSOCK
    }

    /// True while the listener is bound and accepting.
    public var isListening: Bool {
        queue.sync { listenFD >= 0 }
    }

    // MARK: - Listener (all *Locked methods run on `queue`)

    private func startLocked() throws {
        guard listenFD < 0 else { return }
        guard var address = Self.makeSocketAddress(path: socketPath) else {
            throw HookSocketServerError.socketPathTooLong(path: socketPath)
        }
        // The App Support directory may not exist on first launch.
        try? FileManager.default.createDirectory(
            atPath: (socketPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HookSocketServerError.systemCallFailed(operation: "socket", errno: errno)
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        func bindListener() -> Int32 {
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    bind(fd, sockaddrPointer, addressLength)
                }
            }
        }

        var bindResult = bindListener()
        if bindResult != 0, errno == EADDRINUSE {
            if liveListenerAnswers() {
                close(fd)
                throw HookSocketServerError.anotherInstanceRunning(path: socketPath)
            }
            // Crash residue: a socket file nobody answers. Reclaim it.
            unlink(socketPath)
            bindResult = bindListener()
        }
        guard bindResult == 0 else {
            let bindErrno = errno
            close(fd)
            throw HookSocketServerError.systemCallFailed(operation: "bind", errno: bindErrno)
        }

        chmod(socketPath, 0o600)

        guard listen(fd, 16) == 0 else {
            let listenErrno = errno
            close(fd)
            unlink(socketPath)
            throw HookSocketServerError.systemCallFailed(operation: "listen", errno: listenErrno)
        }

        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPendingConnections() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
        logger.debug("Listening on \(self.socketPath, privacy: .public)")
    }

    private func tearDownLocked() {
        acceptSource?.cancel() // cancel handler closes listenFD
        acceptSource = nil
        listenFD = -1
        for connection in connections.values {
            connection.source.cancel() // cancel handler closes the client fd
        }
        connections.removeAll()
        unlink(socketPath)
    }

    /// Probes whether a live listener answers at `socketPath` (bind hit
    /// EADDRINUSE). connect(2) on a UDS is immediate: success = live instance,
    /// ECONNREFUSED = stale file.
    private func liveListenerAnswers() -> Bool {
        guard var address = Self.makeSocketAddress(path: socketPath) else { return false }
        let probeFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probeFD >= 0 else { return false }
        defer { close(probeFD) }
        let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(probeFD, sockaddrPointer, addressLength)
            }
        }
        return result == 0
    }

    // MARK: - Connections

    private func acceptPendingConnections() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                return // EWOULDBLOCK: drained, or listener torn down
            }
            trackConnection(fd: clientFD)
        }
    }

    private func trackConnection(fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let connection = Connection(fd: fd, source: source)
        connections[fd] = connection
        source.setEventHandler { [weak self] in self?.readFromConnection(connection) }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    private func readFromConnection(_ connection: Connection) {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = read(connection.fd, &chunk, chunk.count)
            if bytesRead > 0 {
                connection.buffer.append(contentsOf: chunk[0..<bytesRead])
                if let newlineIndex = connection.buffer.firstIndex(of: 0x0A) {
                    deliver(line: Data(connection.buffer.prefix(upTo: newlineIndex)))
                    closeConnection(connection)
                    return
                }
                if connection.buffer.count >= Self.maxLineBytes {
                    // 4 KB without a newline: parse what we have and move on.
                    deliver(line: connection.buffer)
                    closeConnection(connection)
                    return
                }
                continue
            }
            if bytesRead == 0 {
                // EOF without a trailing newline: tolerate, parse the buffer.
                if !connection.buffer.isEmpty {
                    deliver(line: connection.buffer)
                }
                closeConnection(connection)
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return } // wait for more
            closeConnection(connection)
            return
        }
    }

    private func closeConnection(_ connection: Connection) {
        connections.removeValue(forKey: connection.fd)
        connection.source.cancel() // cancel handler closes the fd
    }

    private func deliver(line: Data) {
        guard !line.isEmpty else { return }
        guard let event = WireEvent(jsonLine: line) else {
            // Tolerance rule (plan 02 §1.4): drop with a debug log, never crash,
            // never affect other connections.
            logger.debug("Dropped undecodable frame (\(line.count, privacy: .public) bytes)")
            return
        }
        continuation.yield(event)
    }

    // MARK: - Address helpers

    /// Builds a sockaddr_un for `path`, or nil when the path (plus NUL) does
    /// not fit sun_path's 104 bytes (plan 02 risk R7).
    static func makeSocketAddress(path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < capacity else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            for (index, byte) in pathBytes.enumerated() { destination[index] = byte }
        }
        return address
    }
}
