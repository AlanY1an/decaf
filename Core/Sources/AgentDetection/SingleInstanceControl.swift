// SingleInstanceControl — what the *losing* copy of the app does after the
// socket bind told it another instance already owns the lock (plan 02 §1.4,
// plan 04 step 1).
//
// The old behaviour was an alert reading "Look for the cup icon in the menu
// bar", followed by termination. That is a dead end for exactly the user it
// was written for: someone who relaunched the app *because* they could not
// find the icon. Reopening an accessory app should bring its interface
// forward — that is the platform convention and it is what the user's hand is
// already trying to do.
//
// Mechanism, and why this one:
//   The socket is already the single-instance lock, it already carries a
//   newline-delimited line protocol, and the losing copy has already
//   connect(2)ed to it once (that probe is how bind failure is told from crash
//   residue). Sending one more line over that same connection adds no new
//   moving part, no new entitlement and no new failure mode. The alternatives
//   were weighed and rejected: DistributedNotificationCenter and a registered
//   URL scheme both deliver into the void with no way to learn whether anyone
//   acted, and an Apple Event would need automation consent to talk to our own
//   app. The deciding factor is the same in all three: none of them can tell
//   "the running instance opened Settings" from "the running instance is
//   wedged", and that distinction is the whole reason for asking.
//
// The wedged case is not hypothetical and it is not detectable by connecting.
// A UNIX-domain connect(2) succeeds as soon as the kernel puts the connection
// on the listen backlog; the owning process need never call accept(). So
// liveness has to be proved by an answer, and the answer is produced by the
// app on the main actor — the same thread that would be wedged. Hence:
// bounded deadline, three outcomes, and the second copy exits under all of
// them.

import Foundation
import HookWire
import os

/// What came back from the running instance.
public enum SingleInstanceReopenOutcome: Equatable, Sendable {
    /// It answered: its Settings window is coming forward. The second copy can
    /// leave without saying anything — the user is about to see the UI.
    case acknowledged
    /// The connection was accepted but no answer arrived inside the deadline,
    /// or the answer was a refusal. The running instance exists and is not
    /// usable; the user needs to be told something they can act on.
    case notResponding
    /// Nothing is listening. The lock holder went away between the failed bind
    /// and this call, or the socket file is crash residue. The caller should
    /// retry taking the lock rather than report anything.
    case noInstance
}

public enum SingleInstanceControl {
    /// The second copy's deadline. Long enough to ride out a main thread that
    /// is merely busy launching, short enough that a user staring at a Dock
    /// bounce does not conclude nothing happened.
    public static let defaultTimeout: TimeInterval = 2.0

    /// Read cap on the answer line. The answer is ~45 bytes; anything larger is
    /// not our protocol.
    static let maxReplyBytes = 4096

    private static let logger = Logger(subsystem: "io.github.alany1an.decaf", category: "SingleInstanceControl")

    /// Asks whoever owns `socketPath` to surface its UI, and waits at most
    /// `timeout` for the answer. Never blocks longer than that, never throws.
    public static func requestReopenUI(
        socketPath: String = HookSocketServer.defaultSocketPath,
        timeout: TimeInterval = SingleInstanceControl.defaultTimeout
    ) -> SingleInstanceReopenOutcome {
        let deadline = Date().addingTimeInterval(timeout)
        guard let request = ControlRequest(control: ControlCommand.reopenUI).encodedLineData() else {
            return .notResponding
        }

        switch connect(to: socketPath, deadline: deadline) {
        case .refused:
            return .noInstance
        case .timedOut:
            // The backlog is full or the kernel made us wait: someone owns the
            // path and is not draining it. That is the wedged case, not an
            // absent one.
            return .notResponding
        case .connected(let fd):
            defer { close(fd) }
            guard writeAll(request, to: fd, deadline: deadline) else { return .notResponding }
            guard let line = readLine(from: fd, deadline: deadline),
                  let response = ControlResponse(jsonLine: line) else {
                logger.debug("no control answer before the deadline")
                return .notResponding
            }
            guard response.control == ControlCommand.reopenUI, response.ok else {
                return .notResponding
            }
            return .acknowledged
        }
    }

    // MARK: - Bounded POSIX plumbing

    private enum ConnectResult {
        case connected(Int32)
        /// ECONNREFUSED / ENOENT: nothing is listening at the path.
        case refused
        /// Connected neither way before the deadline.
        case timedOut
    }

    /// Non-blocking connect + poll, so a path that exists but is not being
    /// drained cannot park the caller indefinitely.
    private static func connect(to socketPath: String, deadline: Date) -> ConnectResult {
        guard var address = HookSocketServer.makeSocketAddress(path: socketPath) else {
            return .refused
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .refused }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, length)
            }
        }
        if result == 0 { return .connected(fd) }

        let connectErrno = errno
        guard connectErrno == EINPROGRESS || connectErrno == EAGAIN || connectErrno == EALREADY else {
            close(fd)
            // ECONNREFUSED (residue file), ENOENT (no file) and anything else
            // unexpected all mean "no usable instance at this path".
            return .refused
        }
        guard poll(fd: fd, events: Int16(POLLOUT), deadline: deadline) else {
            close(fd)
            return .timedOut
        }
        var socketError: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size)
        guard socketError == 0 else {
            close(fd)
            return socketError == ETIMEDOUT ? .timedOut : .refused
        }
        return .connected(fd)
    }

    private static func writeAll(_ data: Data, to fd: Int32, deadline: Date) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0, errno == EINTR { continue }
                if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    guard poll(fd: fd, events: Int16(POLLOUT), deadline: deadline) else { return false }
                    continue
                }
                return false
            }
            return true
        }
    }

    /// Reads up to the first "\n" (exclusive) or the deadline, whichever first.
    private static func readLine(from fd: Int32, deadline: Date) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 512)
        while buffer.count < maxReplyBytes {
            let bytesRead = read(fd, &chunk, chunk.count)
            if bytesRead > 0 {
                buffer.append(contentsOf: chunk[0..<bytesRead])
                if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    return Data(buffer.prefix(upTo: newlineIndex))
                }
                continue
            }
            if bytesRead == 0 {
                // Peer closed without answering — a definite non-answer.
                return buffer.isEmpty ? nil : buffer
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                guard poll(fd: fd, events: Int16(POLLIN), deadline: deadline) else { return nil }
                continue
            }
            return nil
        }
        return buffer
    }

    /// True when `fd` became ready before `deadline`.
    private static func poll(fd: Int32, events: Int16, deadline: Date) -> Bool {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let ready = Darwin.poll(&descriptor, 1, Int32(remaining * 1000))
            if ready > 0 { return true }
            if ready == 0 { return false }
            if errno == EINTR { continue }
            return false
        }
    }
}
