// caff-bridge — hook-to-socket bridge executable (plan 02 §1.3, plan 06 §2).
//
// Execution contract (all hard requirements, plan 02 §1.3):
//   1. signal(SIGPIPE, SIG_IGN) first, then a watchdog thread enforces the
//      <100 ms hard budget: _exit(0) after 90 ms no matter what.
//   2. Read stdin to EOF (256 KB cap — only the head fields are needed;
//      UserPromptSubmit prompt bodies may exceed the cap and are truncated).
//   3. Parse session_id / hook_event_name / cwd from the JSON. The Notification
//      matcher tag comes from argv (plan 02 §1.5 writes it into settings.json;
//      our own argv is more reliable than guessing stdin fields).
//   4. Resolve the agent pid: getppid(), walking past up to 2 shell ancestors
//      (Claude Code may run hooks via /bin/sh -c without the shell exec'ing
//      itself away, plan 02 §1.3 step 4 / risk R3).
//   5. Connect the UNIX socket (50 ms connect timeout + SO_SNDTIMEO), write a
//      single WireEvent JSON line, close, exit(0).
//   6. ANY failure — no socket, connection refused, malformed JSON, bad
//      stdin — exits 0 silently. Never write stdout (UserPromptSubmit hook
//      stdout is injected as context), never write stderr, never return
//      non-zero (exit code 2 would block Claude's action).
//
// Dependency discipline (review decision R4): imports HookWire ONLY (+ system).

import Foundation
import HookWire

// MARK: - Constants (plan 02 §5)

/// Watchdog deadline: 90 ms leaves 10 ms headroom inside the 100 ms budget.
private let bridgeDeadlineMicroseconds: useconds_t = 90_000
/// Connect timeout, subordinate to the total budget (plan 02 §5).
private let connectTimeoutMilliseconds: Int32 = 50
/// SO_SNDTIMEO for the single write, same 50 ms sub-budget.
private let sendTimeoutMicroseconds: Int32 = 50_000
/// stdin read cap (plan 02 §1.3 step 2).
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

// MARK: - Hook payload parsing

private struct HookPayload {
    let sessionID: String
    let eventName: String
    let cwd: String?
}

/// Scans (possibly truncated) JSON text for a top-level-ish `"name": "value"`
/// string field. No escape handling — session ids, event names, and ordinary
/// cwd paths never contain escapes; bail out on anything exotic rather than
/// guess. Used only when full JSON parsing fails (256 KB truncation salvage).
private func scanStringField(_ name: String, in text: String) -> String? {
    let needle = "\"\(name)\""
    var searchRange = text.startIndex..<text.endIndex
    while let keyRange = text.range(of: needle, range: searchRange) {
        searchRange = keyRange.upperBound..<text.endIndex
        // Skip occurrences escaped inside another string value (\"name\").
        if keyRange.lowerBound > text.startIndex,
           text[text.index(before: keyRange.lowerBound)] == "\\" {
            continue
        }
        var cursor = keyRange.upperBound
        while cursor < text.endIndex, " \t\n\r".contains(text[cursor]) {
            cursor = text.index(after: cursor)
        }
        guard cursor < text.endIndex, text[cursor] == ":" else { continue }
        cursor = text.index(after: cursor)
        while cursor < text.endIndex, " \t\n\r".contains(text[cursor]) {
            cursor = text.index(after: cursor)
        }
        guard cursor < text.endIndex, text[cursor] == "\"" else { continue }
        let valueStart = text.index(after: cursor)
        var valueCursor = valueStart
        while valueCursor < text.endIndex {
            let character = text[valueCursor]
            if character == "\\" { return nil }           // escapes: give up
            if character == "\"" { return String(text[valueStart..<valueCursor]) }
            valueCursor = text.index(after: valueCursor)
        }
        return nil                                        // truncated inside the value
    }
    return nil
}

private func parseHookPayload(_ data: Data) -> HookPayload? {
    guard !data.isEmpty else { return nil }
    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let sessionID = object["session_id"] as? String,
       let eventName = object["hook_event_name"] as? String {
        return HookPayload(sessionID: sessionID, eventName: eventName, cwd: object["cwd"] as? String)
    }
    // Salvage path for payloads truncated by the 256 KB cap: only the head
    // fields matter (plan 02 §1.3 step 2 — UserPromptSubmit prompt bodies are
    // expendable). Truncated UTF-8 can end mid-scalar; fall back to Latin-1,
    // which never fails and preserves the ASCII head fields.
    guard let text = String(data: data, encoding: .utf8)
        ?? String(data: data, encoding: .isoLatin1) else { return nil }
    guard let sessionID = scanStringField("session_id", in: text),
          let eventName = scanStringField("hook_event_name", in: text) else { return nil }
    return HookPayload(sessionID: sessionID, eventName: eventName, cwd: scanStringField("cwd", in: text))
}

// MARK: - Agent pid resolution (plan 02 §1.3 step 4)

private func processNameAndParent(of pid: pid_t) -> (name: String, ppid: pid_t)? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
        String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    return (name, info.kp_eproc.e_ppid)
}

private func resolveAgentPID() -> pid_t {
    var pid = getppid()
    let shellNames: Set<String> = ["sh", "bash", "zsh", "dash"]
    for _ in 0..<2 {
        guard let parentInfo = processNameAndParent(of: pid),
              shellNames.contains(parentInfo.name),
              parentInfo.ppid > 0 else { break }
        pid = parentInfo.ppid
    }
    return pid
}

// MARK: - Socket (plan 02 §1.3 step 5, §1.4)

private func connectToSocket(path: String) -> Int32? {
    var address = sockaddr_un()
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < capacity else { return nil }  // sun_path 104-byte limit
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

// MARK: - Main (contract step order is load-bearing)

// Step 1: never die to SIGPIPE, and never outlive the 90 ms deadline.
signal(SIGPIPE, SIG_IGN)
Thread.detachNewThread {
    usleep(bridgeDeadlineMicroseconds)
    _exit(0)
}

// Step 2: stdin.
let stdinData = readStandardInput(cap: stdinByteCap)

// Step 3: payload head fields + argv matcher.
guard let payload = parseHookPayload(stdinData) else { exit(0) }
let matcher = CommandLine.arguments.dropFirst().first.flatMap { $0.isEmpty ? nil : $0 }

// Step 4: agent pid.
let agentPID = resolveAgentPID()

let wireEvent = WireEvent(
    agent: .claudeCode,
    event: payload.eventName,
    sessionID: payload.sessionID,
    ppid: agentPID,
    cwd: payload.cwd,
    matcher: matcher,
    ts: Date().timeIntervalSince1970
)
guard let lineData = wireEvent.encodedLineData() else { exit(0) }

// Step 5: connect and write one line. CAFF_BRIDGE_SOCKET is a test/bench-only
// override; real hooks always use the App Support socket (plan 02 §1.4).
let socketPath = ProcessInfo.processInfo.environment["CAFF_BRIDGE_SOCKET"]
    ?? (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Application Support/Caffeinate/agent.sock")
guard let socketFD = connectToSocket(path: socketPath) else { exit(0) }
_ = writeAll(lineData, to: socketFD)
close(socketFD)

// Step 6: every path ends here.
exit(0)
