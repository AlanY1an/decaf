// StatuslineSettingsEditorTests — plan 09 M2 Task 3. Pure functions over the
// `statusLine` key: install captures the user's previous value (for chain
// passthrough), uninstall restores it, and nothing else in the file moves.

import Foundation
import Testing
@testable import DecafCore

private let userStatusLine: [String: Any] = [
    "type": "command",
    "command": "~/.claude/hud.sh",
    "padding": 0,
]

private let unrelatedSettings: [String: Any] = [
    "model": "opus",
    "hooks": ["Stop": [["hooks": [["type": "command", "command": "user-thing"]]]]],
]

@Suite("StatuslineSettingsEditor")
struct StatuslineSettingsEditorTests {

    @Test func installIntoEmptySettings() throws {
        let result = StatuslineSettingsEditor.install(into: [:])
        #expect(result.capturedPrevious == nil)
        let statusLine = try #require(result.settings["statusLine"] as? [String: Any])
        #expect(statusLine["type"] as? String == "command")
        let command = try #require(statusLine["command"] as? String)
        #expect(command.contains(ClaudeSettingsEditor.markerSubstring))
        #expect(command.contains("decaf-statusline"))
    }

    @Test func installPreservesEverythingElse() throws {
        let result = StatuslineSettingsEditor.install(into: unrelatedSettings)
        var expected = unrelatedSettings
        expected["statusLine"] = result.settings["statusLine"]
        #expect(ClaudeSettingsEditor.semanticallyEqual(result.settings, expected))
    }

    @Test func installOverUserStatuslineCapturesIt() throws {
        var settings = unrelatedSettings
        settings["statusLine"] = userStatusLine
        let result = StatuslineSettingsEditor.install(into: settings)
        let captured = try #require(result.capturedPrevious)
        #expect(NSDictionary(dictionary: captured).isEqual(to: userStatusLine))
        #expect(StatuslineSettingsEditor.isOurs(result.settings))
    }

    @Test func installIsIdempotent() throws {
        let once = StatuslineSettingsEditor.install(into: [:]).settings
        let twice = StatuslineSettingsEditor.install(into: once)
        #expect(twice.capturedPrevious == nil)
        #expect(ClaudeSettingsEditor.semanticallyEqual(twice.settings, once))
    }

    @Test func uninstallRestoresThePreviousValue() throws {
        var settings = unrelatedSettings
        settings["statusLine"] = userStatusLine
        let installed = StatuslineSettingsEditor.install(into: settings)
        let restored = StatuslineSettingsEditor.uninstall(
            from: installed.settings, restoring: installed.capturedPrevious)
        #expect(ClaudeSettingsEditor.semanticallyEqual(restored, settings))
    }

    @Test func uninstallWithoutPreviousRemovesTheKey() throws {
        let installed = StatuslineSettingsEditor.install(into: unrelatedSettings)
        let restored = StatuslineSettingsEditor.uninstall(
            from: installed.settings, restoring: nil)
        #expect(ClaudeSettingsEditor.semanticallyEqual(restored, unrelatedSettings))
    }

    @Test func uninstallNeverTouchesAForeignStatusline() throws {
        var settings = unrelatedSettings
        settings["statusLine"] = userStatusLine
        let untouched = StatuslineSettingsEditor.uninstall(from: settings, restoring: nil)
        #expect(ClaudeSettingsEditor.semanticallyEqual(untouched, settings))
    }

    @Test func isOursIsMarkerBased() {
        #expect(StatuslineSettingsEditor.isOurs([:]) == false)
        var settings: [String: Any] = ["statusLine": userStatusLine]
        #expect(StatuslineSettingsEditor.isOurs(settings) == false)
        settings = StatuslineSettingsEditor.install(into: settings).settings
        #expect(StatuslineSettingsEditor.isOurs(settings) == true)
    }

    @Test func chainFilePayloadShape() throws {
        let with = StatuslineSettingsEditor.chainFilePayload(previous: userStatusLine)
        #expect(with["version"] as? Int == 1)
        let previous = try #require(with["previous"] as? [String: Any])
        #expect(NSDictionary(dictionary: previous).isEqual(to: userStatusLine))

        let without = StatuslineSettingsEditor.chainFilePayload(previous: nil)
        #expect(without["version"] as? Int == 1)
        #expect(without["previous"] == nil)
    }
}
