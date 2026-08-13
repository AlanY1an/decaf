// decaf-statusline — statusline-to-socket bridge executable (plan 09 M2).
//
// Claude Code invokes the configured statusLine command with a JSON status
// payload on stdin and renders the first stdout line. This binary:
//   1. signal(SIGPIPE, SIG_IGN); a watchdog thread _exit(0)s at 4 s — the
//      chained user command may legitimately take a while, so the fuse is
//      generous; our own socket work has its own 50 ms sub-budgets.
//   2. Reads stdin to EOF (256 KB cap).
//   3. Parses the pinned quota surface (HookWire.StatuslineInput) and fires
//      one WireEvent(event: "Statusline", quota:) at the app socket.
//      Fire-and-forget: no listener, no socket, bad JSON — all silent.
//   4. Chains: statusline-chain.json (written by the installer next to the
//      socket) names the user's original statusline command; run it via
//      /bin/sh -c with the ORIGINAL stdin bytes, pass its stdout through.
//   5. No chain (or chain failed): print a minimal default line from the
//      parsed model + five-hour percentage. Empty output when nothing parsed.
//   6. Never write stderr; every path exits 0 (a broken statusline must never
//      break Claude Code's rendering).
//
// Dependency discipline (review decision R4, same as decaf-bridge): imports
// HookWire ONLY (+ system).

import Foundation
import HookWire

// MARK: - Constants

/// Watchdog fuse. Generous on purpose: it bounds the CHAINED command too.
private let watchdogDeadlineMicroseconds: useconds_t = 4_000_000
/// Socket connect timeout, sub-budget of our own work (plan 02 §5 values).
private let connectTimeoutMilliseconds: Int32 = 50
/// SO_SNDTIMEO for the single write.
private let sendTimeoutMicroseconds: Int32 = 50_000
/// stdin read cap.
private let stdinByteCap = 256 * 1024

// MARK: - stdin

private func readStandardInput(cap: Int) -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while data.count < cap {
        let wanted = min(buffer.count, cap - data.count)
        let bytesRead = read(0, &buffer, wanted)
        if bytesRead > 0 {
            data.append(contentsOf: buffer[0..<bytesRead])
        } else if bytesRead < 0 && errno == EINTR {
            continue
        } else {
            break // EOF or error: use what we have
        }
    }
    return data
}

// MARK: - Socket (same helpers as decaf-bridge)

private func connectToSocket(path: String) -> Int32? {
    var address = sockaddr_un()
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < capacity else { return nil }
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        for (index, byte) in pathBytes.enumerated() { destination[index] = byte }
    }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }

    let originalFlags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK)

    let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connectResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            connect(fd, sockaddrPointer, addressLength)
        }
    }
    if connectResult != 0 {
        guard errno == EINPROGRESS else {
            close(fd)
            return nil
        }
        var pollDescriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pollDescriptor, 1, connectTimeoutMilliseconds) == 1 else {
            close(fd)
            return nil
        }
        var connectError: Int32 = 0
        var errorLength = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &connectError, &errorLength) == 0,
              connectError == 0 else {
            close(fd)
            return nil
        }
    }

    _ = fcntl(fd, F_SETFL, originalFlags)
    var sendTimeout = timeval(tv_sec: 0, tv_usec: suseconds_t(sendTimeoutMicroseconds))
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
    return fd
}

private func writeAll(_ data: Data, to fd: Int32) -> Bool {
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        guard let base = raw.baseAddress else { return false }
        var offset = 0
        while offset < raw.count {
            let written = write(fd, base + offset, raw.count - offset)
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}

// MARK: - Chain

/// The user's original statusline command, from the sidecar the installer
/// wrote: {"version":1,"previous":{"type":"command","command":"…"}}.
private func chainedCommand(appSupportDirectory: String) -> String? {
    let path = (appSupportDirectory as NSString)
        .appendingPathComponent("statusline-chain.json")
    guard let data = FileManager.default.contents(atPath: path),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let previous = object["previous"] as? [String: Any],
          let command = previous["command"] as? String,
          !command.isEmpty
    else { return nil }
    return command
}

/// Runs the chained command with the original stdin bytes; returns its stdout
/// on success. The watchdog thread is the overall fuse. stderr is discarded.
private func runChain(command: String, stdinData: Data) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return nil
    }
    // POSIX write, not FileHandle.write: a chain command that exits before
    // reading its stdin turns the pipe dead, and FileHandle.write answers
    // EPIPE with an ObjC exception Swift cannot catch. SIGPIPE is already
    // ignored, so the raw syscall just returns -1 and we move on — the chain
    // may still have produced output worth passing through.
    let stdinFD = stdinPipe.fileHandleForWriting.fileDescriptor
    _ = writeAll(stdinData, to: stdinFD)
    try? stdinPipe.fileHandleForWriting.close()
    let output = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return output
}

// MARK: - Default line

private func defaultLine(from input: StatuslineInput?) -> String {
    guard let quota = input?.quota else { return "" }
    var parts: [String] = []
    if let name = quota.modelDisplayName, !name.isEmpty {
        parts.append(name)
    }
    if let percent = quota.fiveHourUsedPercent {
        parts.append("5h \(Int(percent.rounded()))%")
    }
    return parts.joined(separator: " | ")
}

// MARK: - Main

signal(SIGPIPE, SIG_IGN)
Thread.detachNewThread {
    usleep(watchdogDeadlineMicroseconds)
    _exit(0)
}

let stdinData = readStandardInput(cap: stdinByteCap)
let input = StatuslineInput.parse(stdinData)

// Fire the quota frame (fire-and-forget; DECAF_BRIDGE_SOCKET is the same
// test/bench-only override decaf-bridge honors, and
// DECAF_STATUSLINE_APPSUPPORT relocates the chain sidecar for check scripts).
let appSupport = ProcessInfo.processInfo.environment["DECAF_STATUSLINE_APPSUPPORT"]
    ?? (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Application Support/Decaf")
if let input {
    let wireEvent = WireEvent(
        agent: .claudeCode,
        event: WireEvent.statuslineEventName,
        sessionID: input.sessionID ?? "",
        ppid: getppid(),
        ts: Date().timeIntervalSince1970,
        quota: input.quota
    )
    let socketPath = ProcessInfo.processInfo.environment["DECAF_BRIDGE_SOCKET"]
        ?? (appSupport as NSString).appendingPathComponent("agent.sock")
    if let lineData = wireEvent.encodedLineData(),
       let socketFD = connectToSocket(path: socketPath) {
        _ = writeAll(lineData, to: socketFD)
        close(socketFD)
    }
}

// Chain to the user's original statusline, or fall back to the default line.
if let command = chainedCommand(appSupportDirectory: appSupport),
   let output = runChain(command: command, stdinData: stdinData) {
    FileHandle.standardOutput.write(output)
} else {
    let line = defaultLine(from: input)
    if !line.isEmpty {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

exit(0)
