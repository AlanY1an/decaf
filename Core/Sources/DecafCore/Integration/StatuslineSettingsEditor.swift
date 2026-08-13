// StatuslineSettingsEditor — PURE functions for the `statusLine` key of
// `~/.claude/settings.json` (plan 09 M2). Same discipline as
// ClaudeSettingsEditor: zero IO, golden-testable, semantic-equality contract.
//
// Unlike hooks (arrays we append to), `statusLine` is a single slot: Claude
// Code runs exactly one command. So installing over an existing user value
// REPLACES it and captures the original; decaf-statusline then chains to the
// captured command at render time (reading the sidecar this file's
// `chainFilePayload` describes), and uninstall puts the original back. The
// user's statusline keeps working the whole time — it is wrapped, not lost.

import Foundation

public enum StatuslineSettingsEditor {

    /// `$HOME` stays literal (the shell expands it); quoted because the path
    /// contains a space — same rules as ClaudeSettingsEditor.bridgePath.
    public static let statuslinePath = "$HOME/Library/Application Support/Decaf/bin/decaf-statusline"

    public static let quotedCommand = "\"\(statuslinePath)\""

    /// Sidecar next to the socket and the session store:
    /// ~/Library/Application Support/Decaf/statusline-chain.json
    public static let chainFileName = "statusline-chain.json"

    /// Installs our command into the `statusLine` slot.
    ///
    /// Returns the new settings plus the user's previous `statusLine` object
    /// when one was replaced — the caller persists it into the chain sidecar
    /// (and into the uninstall path). Installing over our own entry captures
    /// nothing and changes nothing.
    public static func install(
        into settings: [String: Any]
    ) -> (settings: [String: Any], capturedPrevious: [String: Any]?) {
        var result = settings
        var captured: [String: Any]?
        if let existing = settings["statusLine"] as? [String: Any] {
            if entryIsOurs(existing) {
                return (settings, nil)
            }
            captured = existing
        }
        result["statusLine"] = [
            "type": "command",
            "command": quotedCommand,
        ]
        return (result, captured)
    }

    /// Removes our entry, restoring `previous` when one was captured at
    /// install time. A `statusLine` that is not ours is never touched — the
    /// user replaced us after install, and their choice wins.
    public static func uninstall(
        from settings: [String: Any],
        restoring previous: [String: Any]?
    ) -> [String: Any] {
        guard let existing = settings["statusLine"] as? [String: Any],
              entryIsOurs(existing)
        else { return settings }
        var result = settings
        if let previous {
            result["statusLine"] = previous
        } else {
            result.removeValue(forKey: "statusLine")
        }
        return result
    }

    /// True when the `statusLine` slot holds our command (marker-based, same
    /// marker as the hooks installer — it can only point into our App Support
    /// directory).
    public static func isOurs(_ settings: [String: Any]) -> Bool {
        guard let existing = settings["statusLine"] as? [String: Any] else { return false }
        return entryIsOurs(existing)
    }

    /// The sidecar decaf-statusline reads to find the wrapped command:
    /// `{"version": 1, "previous": {…the user's statusLine object…}}` — the
    /// `previous` key is absent when the user had no statusline before us.
    public static func chainFilePayload(previous: [String: Any]?) -> [String: Any] {
        var payload: [String: Any] = ["version": 1]
        if let previous {
            payload["previous"] = previous
        }
        return payload
    }

    private static func entryIsOurs(_ entry: [String: Any]) -> Bool {
        guard let command = entry["command"] as? String else { return false }
        return command.contains(ClaudeSettingsEditor.markerSubstring)
    }
}
