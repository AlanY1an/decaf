// Contract tests for the HookWire module (plan 02 §1.4, plan 06 §2).
// Deep behavioral coverage belongs to the detection module agent; these pin the
// wire shape and the tolerance rules that other agents build against.

import Foundation
import Testing
@testable import HookWire

@Suite struct HookWireContractTests {
    @Test func wireEventRoundTripsThroughSingleLineJSON() throws {
        let event = WireEvent(
            agent: .claudeCode,
            event: "UserPromptSubmit",
            sessionID: "abc-123",
            ppid: 48291,
            cwd: "/Users/alan/Project/X",
            matcher: nil,
            ts: 1_785_650_000.123
        )
        let line = try #require(event.encodedLine())
        #expect(line.hasSuffix("\n"))
        #expect(!line.dropLast().contains("\n"), "wire frames must be single-line")

        let decoded = try #require(WireEvent(jsonLine: line))
        #expect(decoded == event)
        #expect(decoded.agentKind == .claudeCode)
    }

    @Test func decoderUsesSnakeCaseSessionIDKey() throws {
        let line = #"{"v":1,"agent":"claude","event":"Stop","session_id":"s1","ppid":7,"ts":1.5}"#
        let decoded = try #require(WireEvent(jsonLine: line))
        #expect(decoded.sessionID == "s1")
        #expect(decoded.cwd == nil)
        #expect(decoded.matcher == nil)
    }

    @Test func unknownFieldsEventNamesAndVersionsAreTolerated() throws {
        // Unknown field, unknown event name, future version — must decode, not crash.
        let line = #"{"v":99,"agent":"claude","event":"BrandNewHook","session_id":"s2","ppid":1,"ts":2.0,"mystery":true}"#
        let decoded = try #require(WireEvent(jsonLine: line))
        #expect(decoded.v == 99)
        #expect(decoded.event == "BrandNewHook")

        // Unknown agent decodes too; only agentKind resolution returns nil.
        let alien = #"{"v":1,"agent":"somebot","event":"Stop","session_id":"s3","ppid":1,"ts":3.0}"#
        let alienDecoded = try #require(WireEvent(jsonLine: alien))
        #expect(alienDecoded.agentKind == nil)
    }

    @Test func malformedInputReturnsNilInsteadOfCrashing() {
        #expect(WireEvent(jsonLine: "not json at all") == nil)
        #expect(WireEvent(jsonLine: "") == nil)
        #expect(WireEvent(jsonLine: #"{"v":1}"#) == nil)
    }

    @Test func agentKindRawValuesMatchTheWireProtocol() {
        #expect(AgentKind.claudeCode.rawValue == "claude")
        #expect(AgentKind.codex.rawValue == "codex")
        #expect(AgentKind.opencode.rawValue == "opencode")
    }
}
