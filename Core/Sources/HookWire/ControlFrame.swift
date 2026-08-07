// ControlFrame — the request/response pair a second copy of the app uses to
// ask the running instance to surface its UI (plan 02 §1.4 control extension,
// plan 04 step 1).
//
// Why this shares the hook socket rather than inventing a channel: the socket
// bind IS the single-instance lock, so by the time a second copy knows it lost
// the race it is already holding the running instance's address, and it has
// already connect(2)ed to it once to tell a live listener from crash residue.
// Adding a frame costs nothing; a distributed notification or an Apple Event
// would be a second mechanism with a second failure mode and — the deciding
// point — no way to tell "delivered and acted on" from "delivered into a
// process whose main thread is wedged".
//
// The hook protocol is fire-and-forget with no reply (plan 02 §1.4). Control
// frames are the one exception and they must be: the whole reason the second
// copy asks is so it can decide whether it may exit quietly, and a request
// with no answer is indistinguishable from a request into the void.
//
// Frame shapes (single-line JSON + "\n", same framing as WireEvent):
//   request  {"control":"reopen-ui","v":1}
//   response {"control":"reopen-ui","ok":true,"v":1}
//
// Disambiguation from hook frames: `control` is a reserved key that never
// appears on a WireEvent, and a control frame carries no `event`. Receivers
// try ControlRequest first and fall through to WireEvent — see
// HookSocketServer.handleControlIfNeeded and its test.

import Foundation

/// Control verbs understood on the socket. Unknown verbs are answered
/// `ok: false` rather than ignored, so an older running instance meeting a
/// newer second copy produces a definite answer instead of a hang.
public enum ControlCommand {
    /// "Bring your interface forward." The running instance opens and focuses
    /// the Settings window — the one part of this app's UI that a crowded menu
    /// bar, a notch or a third-party menu-bar manager cannot swallow.
    public static let reopenUI = "reopen-ui"
}

/// A control frame sent to the running instance.
public struct ControlRequest: Equatable, Sendable, Codable {
    public static let currentVersion = 1

    /// Protocol version. Receivers must tolerate unknown values.
    public var v: Int
    /// The verb; see `ControlCommand`.
    public var control: String

    public init(control: String, v: Int = ControlRequest.currentVersion) {
        self.v = v
        self.control = control
    }
}

/// The running instance's answer. Reaching the point where this is produced is
/// itself the liveness proof: the app builds it on the main actor, after the
/// UI work has been kicked off.
public struct ControlResponse: Equatable, Sendable, Codable {
    public static let currentVersion = 1

    public var v: Int
    /// Echoes the request's verb, so a caller can tell an answer to its own
    /// question from a stray frame.
    public var control: String
    /// True when the running instance understood the verb and acted on it.
    public var ok: Bool

    public init(control: String, ok: Bool, v: Int = ControlResponse.currentVersion) {
        self.v = v
        self.control = control
        self.ok = ok
    }
}

// MARK: - Single-line JSON encode/decode

extension ControlRequest {
    /// Decodes a control request, or nil when the line is anything else —
    /// including a perfectly valid hook frame, which has no `control` key.
    /// Never throws.
    public init?(jsonLine data: Data) {
        guard let request = try? JSONDecoder().decode(ControlRequest.self, from: data) else {
            return nil
        }
        self = request
    }

    public func encodedLineData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(self) else { return nil }
        data.append(0x0A) // "\n"
        return data
    }
}

extension ControlResponse {
    public init?(jsonLine data: Data) {
        guard let response = try? JSONDecoder().decode(ControlResponse.self, from: data) else {
            return nil
        }
        self = response
    }

    public func encodedLineData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(self) else { return nil }
        data.append(0x0A) // "\n"
        return data
    }
}
