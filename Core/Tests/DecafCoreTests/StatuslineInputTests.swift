// StatuslineInputTests — plan 09 M2 Task 2. Pins the statusline stdin read
// surface: rate_limits + model identity, nothing else. The sentinel planted
// in sibling fields (workspace, cost) must never surface in any output.

import Foundation
import Testing
import HookWire

private let sentinel = "STATUSLINE-SENTINEL-DO-NOT-LEAK-5e7b02"

private let fullInput = """
{"session_id":"sess-1","model":{"id":"claude-opus-4-5","display_name":"Opus 4.5"},\
"workspace":{"current_dir":"\(sentinel)"},"cost":{"total_cost_usd":1.23,"note":"\(sentinel)"},\
"rate_limits":{"five_hour":{"used_percentage":34.2,"resets_at":"2026-08-07T12:00:00Z"},\
"seven_day":{"used_percentage":12.5,"resets_at":"2026-08-11T00:00:00Z"}}}
"""

@Suite("StatuslineInput")
struct StatuslineInputTests {

    @Test func parsesTheFullShape() throws {
        let input = try #require(StatuslineInput.parse(Data(fullInput.utf8)))
        #expect(input.sessionID == "sess-1")
        #expect(input.quota.modelID == "claude-opus-4-5")
        #expect(input.quota.modelDisplayName == "Opus 4.5")
        #expect(input.quota.fiveHourUsedPercent == 34.2)
        #expect(input.quota.fiveHourResetsAt == "2026-08-07T12:00:00Z")
        #expect(input.quota.sevenDayUsedPercent == 12.5)
        #expect(input.quota.sevenDayResetsAt == "2026-08-11T00:00:00Z")
    }

    @Test func missingRateLimitsStillYieldsModel() throws {
        let json = #"{"session_id":"s","model":{"id":"m","display_name":"M"}}"#
        let input = try #require(StatuslineInput.parse(Data(json.utf8)))
        #expect(input.quota.modelID == "m")
        #expect(input.quota.fiveHourUsedPercent == nil)
        #expect(input.quota.sevenDayResetsAt == nil)
    }

    @Test func wrongTypedPercentageIsDroppedNotGarbled() throws {
        let json = #"{"model":{"id":"m"},"rate_limits":{"five_hour":{"used_percentage":"34","resets_at":"x"}}}"#
        let input = try #require(StatuslineInput.parse(Data(json.utf8)))
        #expect(input.quota.fiveHourUsedPercent == nil)
        #expect(input.quota.fiveHourResetsAt == "x")
    }

    @Test(arguments: ["", "garbage", "[1,2,3]", "42"])
    func hostileInputYieldsNilNeverThrows(text: String) {
        #expect(StatuslineInput.parse(Data(text.utf8)) == nil)
    }

    @Test func readSurfaceIsExactlyThePinnedKeys() {
        #expect(StatuslineInput.RootKey.allCases.map(\.rawValue)
            == ["session_id", "model", "rate_limits"])
        #expect(StatuslineInput.ModelKey.allCases.map(\.rawValue)
            == ["id", "display_name"])
        #expect(StatuslineInput.RateLimitsKey.allCases.map(\.rawValue)
            == ["five_hour", "seven_day"])
        #expect(StatuslineInput.WindowKey.allCases.map(\.rawValue)
            == ["used_percentage", "resets_at"])
    }

    @Test func siblingFieldsNeverLeak() throws {
        let input = try #require(StatuslineInput.parse(Data(fullInput.utf8)))
        for value in [
            input.sessionID ?? "", input.quota.modelID ?? "",
            input.quota.modelDisplayName ?? "",
            input.quota.fiveHourResetsAt ?? "", input.quota.sevenDayResetsAt ?? "",
        ] {
            #expect(!value.contains(sentinel))
        }
    }
}
