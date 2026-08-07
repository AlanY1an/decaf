// The rows under the status line, and the presets the menu shares with
// Settings — the arithmetic and wording the app target genuinely owns rather
// than forwards to CaffeinateCore.

import Foundation
import Testing
import CaffeinateCore
import HookWire

@Suite struct SessionRowWording {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(phase: SessionPhase, project: String = "api") -> AgentSessionSummary {
        AgentSessionSummary(
            id: "s1", agent: .claudeCode, projectName: project,
            phase: phase, startedAt: start
        )
    }

    @Test func aWorkingRowNamesTheProjectAndHowLong() {
        #expect(MenuTextFormatter.sessionLine(
            for: row(phase: .working), now: start.addingTimeInterval(12 * 60)
        ) == "api — working for 12 min")
    }

    /// The row does not repeat the deadline: the status line above already names
    /// the instant sleep becomes allowed, and printing it twice would make a
    /// five-row menu argue with itself if the two ever diverged.
    @Test func aGraceRowNamesThePhaseAndNotTheInstant() {
        let until = start.addingTimeInterval(180)
        let line = MenuTextFormatter.sessionLine(for: row(phase: .graceIdle(until: until)))
        #expect(line == "api — grace period")
        #expect(!line.contains(MenuTextFormatter.timeString(until)))
    }

    @Test func theProjectNameIsUsedVerbatim() {
        #expect(MenuTextFormatter.sessionLine(
            for: row(phase: .working, project: "my-service"),
            now: start.addingTimeInterval(60)
        ) == "my-service — working for 1 min")
    }
}

@Suite struct WorkingDurationText {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// A session that started seconds ago reads "1 min", never "0 min". Zero is
    /// the one number that would make a live hold look like nothing.
    @Test func subMinuteWorkRoundsUpToOne() {
        #expect(MenuTextFormatter.durationText(since: start, now: start) == "1 min")
        #expect(MenuTextFormatter.durationText(
            since: start, now: start.addingTimeInterval(59)
        ) == "1 min")
    }

    /// A clock that jumped backwards must not produce a negative duration.
    @Test func aBackwardsClockStillReadsAsOneMinute() {
        #expect(MenuTextFormatter.durationText(
            since: start, now: start.addingTimeInterval(-3600)
        ) == "1 min")
    }

    @Test func minutesBelowAnHourStayMinutes() {
        #expect(MenuTextFormatter.durationText(
            since: start, now: start.addingTimeInterval(59 * 60)
        ) == "59 min")
    }

    @Test func aWholeHourDropsTheMinutes() {
        #expect(MenuTextFormatter.durationText(
            since: start, now: start.addingTimeInterval(2 * 3600)
        ) == "2 hr")
    }

    @Test func hoursAndMinutesAreBothShown() {
        #expect(MenuTextFormatter.durationText(
            since: start, now: start.addingTimeInterval(3 * 3600 + 7 * 60)
        ) == "3 hr 7 min")
    }
}

@Suite struct RowFolding {

    @Test func theFoldThresholdIsFive() {
        #expect(MenuTextFormatter.maxSessionRows == 5)
    }

    @Test func theOverflowRowCountsWhatIsHidden() {
        #expect(MenuTextFormatter.overflowLine(hiddenCount: 3) == "3 more sessions…")
    }
}

@Suite struct UntilItemTitles {

    /// Absolute clock time, never a countdown — the menu does not refresh while
    /// it stays open.
    @Test func aTodayDeadlineReadsAsAPlainTime() {
        let deadline = Date(timeIntervalSince1970: 1_800_000_000)
        let option = UntilOption(deadline: deadline, isTomorrow: false)
        #expect(MenuTextFormatter.untilItemTitle(option)
            == "Until \(MenuTextFormatter.timeString(deadline))")
    }

    /// Crossing midnight has to be said out loud: "Until 1:00 AM" on its own
    /// reads as a deadline that has already passed.
    @Test func aDeadlineAcrossMidnightSaysTomorrow() {
        let deadline = Date(timeIntervalSince1970: 1_800_000_000)
        let option = UntilOption(deadline: deadline, isTomorrow: true)
        #expect(MenuTextFormatter.untilItemTitle(option)
            == "Until \(MenuTextFormatter.timeString(deadline)) Tomorrow")
    }

    @Test func theSubmenuIsSpelledWithAnEllipsis() {
        #expect(MenuTextFormatter.untilSubmenuTitle == "Until…")
    }
}

@Suite struct ManualPresets {

    /// Fixed, and in this order (plan 04 §3). The presets are shared with the
    /// General settings popup, so a change here silently changes two surfaces.
    @Test func thePresetListIsTheFixedSeven() {
        #expect(ManualPreset.allCases.map(\.title) == [
            "Indefinitely", "5 Minutes", "15 Minutes", "30 Minutes",
            "1 Hour", "2 Hours", "5 Hours",
        ])
    }

    @Test func everyTitleMatchesItsDuration() {
        #expect(ManualPreset.fiveMinutes.mode == .duration(5 * 60))
        #expect(ManualPreset.fifteenMinutes.mode == .duration(15 * 60))
        #expect(ManualPreset.thirtyMinutes.mode == .duration(30 * 60))
        #expect(ManualPreset.oneHour.mode == .duration(3600))
        #expect(ManualPreset.twoHours.mode == .duration(2 * 3600))
        #expect(ManualPreset.fiveHours.mode == .duration(5 * 3600))
        #expect(ManualPreset.infinite.mode == .infinite)
    }

    /// The reverse lookup is what puts the check mark next to the running hold.
    @Test func matchingFindsThePresetBehindARunningHold() {
        for preset in ManualPreset.allCases {
            #expect(ManualPreset.matching(preset.mode) == preset)
        }
    }

    /// A hold started from "Until 6:00 PM" is not a preset, and no preset may
    /// claim its check mark.
    @Test func anArbitraryDeadlineMatchesNoPreset() {
        #expect(ManualPreset.matching(.duration(7 * 60)) == nil)
        #expect(ManualPreset.matching(.untilDate(Date(timeIntervalSince1970: 1_800_000_000)))
            == nil)
    }
}
