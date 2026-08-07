// Contract tests for the AgentDetection module (plan 02 §0/§1.2).
// State-machine behavior is owned by the detection module agent; these pin the
// data shapes (including sessions.json codability) other agents build against.

import Foundation
import Testing
@testable import AgentDetection

@Suite struct AgentDetectionContractTests {
    @Test func agentSessionRoundTripsThroughJSON() throws {
        let session = AgentSession(
            id: "abc-123",
            agent: .claudeCode,
            startedAt: Date(timeIntervalSince1970: 1_785_650_000),
            ppid: 48291,
            cwd: "/Users/alan/Project/X",
            state: .grace(until: Date(timeIntervalSince1970: 1_785_650_180)),
            lastEventAt: Date(timeIntervalSince1970: 1_785_650_000)
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: data)
        #expect(decoded == session)
    }

    @Test func detectionOutputDefaultsToNotHolding() {
        let output = DetectionOutput()
        #expect(!output.shouldHold)
        #expect(output.holdSources.isEmpty)
        #expect(output.precision.isEmpty)
    }

    @Test func detectionOutputCarriesPerAgentPrecision() {
        let output = DetectionOutput(
            shouldHold: true,
            holdSources: [
                HoldSource(agent: .claudeCode, kind: .session(id: "s1", state: .working)),
                HoldSource(agent: .opencode, kind: .fallbackActivity(lastActivityAt: .now)),
            ],
            precision: [.claudeCode: .hooks, .opencode: .fileActivity, .codex: .unavailable]
        )
        #expect(output.holdSources.count == 2)
        #expect(output.precision[.claudeCode] == .hooks)
        #expect(output.precision[.codex] == .unavailable)
    }

    @Test func reexportedTypesResolveToTheSharedDefinitions() {
        // AgentDetection.AgentKind / .DetectionPrecision are the same types the
        // rest of the app uses (review decisions R12/R14).
        let kind: AgentKind = .claudeCode
        #expect(kind.rawValue == "claude")
        let precision: DetectionPrecision = .fileActivity
        #expect(precision != .hooks)
    }
}
