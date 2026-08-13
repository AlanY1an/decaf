// WireEvent — the single-line JSON frame sent from decaf-bridge to the app socket server.
// The wire protocol's single source of truth is plan 02 §1.4 (review decision R5).
//
// Shape (protocol version `v` starts at 1):
//   {"v":1,"agent":"claude","event":"UserPromptSubmit","session_id":"abc-123",
//    "ppid":48291,"cwd":"/Users/alan/Project/X","matcher":null,"ts":1785650000.123}
//
// Tolerance rules (plan 06 §2, forward compatibility):
// - Unknown JSON fields are ignored on decode.
// - Unknown `v` values and unknown `event` names MUST NOT crash the receiver;
//   `event` is therefore carried as a raw string and normalized downstream by
//   the session state machine (plan 02 §1.1). The bridge is a dumb pipe.
// - `agent` is carried as a raw string for the same reason; use `agentKind`
//   to resolve it against the known `AgentKind` cases.

import Foundation

public struct WireEvent: Equatable, Sendable, Codable {
    /// Current wire protocol version written by this build.
    public static let currentVersion = 1

    /// Protocol version of the frame. Receivers must tolerate unknown values.
    public var v: Int
    /// Raw agent identifier (e.g. "claude"). See `agentKind`.
    public var agent: String
    /// Raw hook event name (e.g. "SessionStart", "UserPromptSubmit", "Stop").
    /// Unknown names must be tolerated by receivers (plan 02 §1.1 forward compat).
    public var event: String
    /// The agent's session identifier (`session_id` on the wire).
    public var sessionID: String
    /// The agent process pid as reported by the bridge (its resolved parent pid).
    public var ppid: Int32
    /// Working directory of the session, when known.
    public var cwd: String?
    /// Notification matcher tag ("permission_prompt" / "idle_prompt"); only
    /// present on Notification events, passed to the bridge via argv (plan 02 §1.5).
    public var matcher: String?
    /// Unix timestamp (seconds since epoch, fractional) when the bridge sent the frame.
    public var ts: Double
    /// Official rate-limit numbers; only on `Statusline` frames (plan 09 M2).
    /// Optional so every pre-M2 frame and receiver keeps working unchanged.
    public var quota: QuotaPayload?

    enum CodingKeys: String, CodingKey {
        case v
        case agent
        case event
        case sessionID = "session_id"
        case ppid
        case cwd
        case matcher
        case ts
        case quota
    }

    public init(
        v: Int = WireEvent.currentVersion,
        agent: String,
        event: String,
        sessionID: String,
        ppid: Int32,
        cwd: String? = nil,
        matcher: String? = nil,
        ts: Double,
        quota: QuotaPayload? = nil
    ) {
        self.v = v
        self.agent = agent
        self.event = event
        self.sessionID = sessionID
        self.ppid = ppid
        self.cwd = cwd
        self.matcher = matcher
        self.ts = ts
        self.quota = quota
    }

    /// Convenience initializer for frames about a known agent.
    public init(
        v: Int = WireEvent.currentVersion,
        agent: AgentKind,
        event: String,
        sessionID: String,
        ppid: Int32,
        cwd: String? = nil,
        matcher: String? = nil,
        ts: Double,
        quota: QuotaPayload? = nil
    ) {
        self.init(
            v: v,
            agent: agent.rawValue,
            event: event,
            sessionID: sessionID,
            ppid: ppid,
            cwd: cwd,
            matcher: matcher,
            ts: ts,
            quota: quota
        )
    }

    /// The known agent this frame refers to, or nil for agents this build does not know.
    public var agentKind: AgentKind? { AgentKind(rawValue: agent) }
}

// MARK: - Single-line JSON encode/decode

extension WireEvent {
    /// Decodes a single wire line (with or without the trailing "\n").
    /// Returns nil for malformed input — never throws, never crashes.
    public init?(jsonLine data: Data) {
        let decoder = JSONDecoder()
        guard let event = try? decoder.decode(WireEvent.self, from: data) else {
            return nil
        }
        self = event
    }

    /// Decodes a single wire line from a string. Returns nil for malformed input.
    public init?(jsonLine string: String) {
        guard let data = string.data(using: .utf8) else { return nil }
        self.init(jsonLine: data)
    }

    /// Encodes the frame as single-line JSON terminated by "\n", ready to be
    /// written to the UNIX socket. Returns nil only if encoding fails (never
    /// expected for this fixed shape).
    public func encodedLineData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(self) else { return nil }
        data.append(0x0A) // "\n"
        return data
    }

    /// String form of `encodedLineData()` (includes the trailing "\n").
    public func encodedLine() -> String? {
        guard let data = encodedLineData() else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
