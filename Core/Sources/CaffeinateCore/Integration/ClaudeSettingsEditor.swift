// ClaudeSettingsEditor — PURE deep-merge functions for `~/.claude/settings.json`
// (plan 03 §3.3 rules 1–5). Input and output are in-memory JSON values; zero IO,
// golden-testable.
//
// The hooks JSON shape is owned by plan 02 §1.5 (sole truth, review decision
// R6); the template below quotes it verbatim:
// - `$HOME`-relative path (settings.json often lives in synced dotfiles;
//   a hard-coded username would break on other machines), and the path MUST be
//   wrapped in double quotes — "Application Support" contains a space and hook
//   commands run through /bin/sh, so an unquoted path fails silently.
// - `Notification` carries its matcher via argv ("$BIN" permission_prompt /
//   "$BIN" idle_prompt); every other event is told apart by the stdin JSON's
//   `hook_event_name`.
// - `timeout: 5` is only a fuse — the bridge's own hard budget is <100ms.
//
// Merge rules (plan 03 §3.3):
// 1. Everything outside the event arrays we touch under `hooks` passes through
//    untouched — no typed model, unknown fields survive.
// 2. Per event: existing array → append our entry; missing → create. User
//    entries are never modified.
// 3. Idempotence: a command containing the marker substring
//    "Application Support/Caffeinate" identifies our entry; if present, skip.
// 4. Uninstall = reverse filter: drop marked entries everywhere; drop event
//    keys that become empty; drop `hooks` if it becomes empty.
// 5. Re-serialization loses key order/indentation (accepted MVP trade-off), so
//    the uninstall contract is SEMANTIC equality after parsing, not byte
//    equality — see `semanticallyEqual(_:_:)`.

import Foundation

public enum ClaudeSettingsEditor {
    /// Thrown when settings.json parsed fine but a value we must edit has an
    /// impossible type (e.g. `hooks` is a string). The installer aborts and
    /// leaves the file untouched — same discipline as a parse failure.
    public enum ShapeError: Error, Equatable {
        case hooksIsNotAnObject
        case eventIsNotAnArray(event: String)
    }

    /// Marker substring identifying our entries (plan 03 §3.3 rule 3). Any hook
    /// command containing it is ours — it can only point at our App Support dir.
    public static let markerSubstring = "Application Support/Caffeinate"

    /// `$BIN` of plan 02 §1.5. `$HOME` stays literal (the shell expands it) and
    /// the value is used only inside double quotes.
    public static let bridgePath = "$HOME/Library/Application Support/Caffeinate/bin/caff-bridge"

    /// The quoted base command: `"$HOME/Library/Application Support/Caffeinate/bin/caff-bridge"`.
    /// Quotes are part of the command string — mandatory, see header note.
    public static let quotedBridgeCommand = "\"\(bridgePath)\""

    /// Fuse timeout for every hook entry (plan 02 §1.5).
    public static let hookTimeout = 5

    /// Events registered without a matcher (plan 02 §1.5).
    public static let plainEvents = ["SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "SessionEnd"]

    /// The two `Notification` matchers, passed via argv (plan 02 §1.5).
    public static let notificationMatchers = ["permission_prompt", "idle_prompt"]

    // MARK: - Template (verbatim from plan 02 §1.5)

    /// One entry of the template: the event name, the optional Notification
    /// matcher, and the JSON object to append to that event's array.
    public struct TemplateEntry {
        public let event: String
        public let matcher: String?
        public var object: [String: Any] {
            var command = ClaudeSettingsEditor.quotedBridgeCommand
            if let matcher { command += " " + matcher }
            let hookItem: [String: Any] = [
                "type": "command",
                "command": command,
                "timeout": ClaudeSettingsEditor.hookTimeout,
            ]
            var entry: [String: Any] = ["hooks": [hookItem]]
            if let matcher { entry["matcher"] = matcher }
            return entry
        }
    }

    /// All seven entries we install: five plain events + two Notification matchers.
    public static func templateEntries() -> [TemplateEntry] {
        plainEvents.map { TemplateEntry(event: $0, matcher: nil) }
            + notificationMatchers.map { TemplateEntry(event: "Notification", matcher: $0) }
    }

    /// The full `{"hooks": {...}}` fragment as it would land in an empty file —
    /// used for consent-dialog previews (`plannedChanges()`).
    public static func hooksFragment() -> [String: Any] {
        (try? merge(ourEntriesInto: [:])) ?? [:]
    }

    // MARK: - Merge (install)

    /// Appends our entries into `settings` per rules 1–3. Throws `ShapeError`
    /// when the existing structure cannot hold our entries; callers abort
    /// without touching the file.
    public static func merge(ourEntriesInto settings: [String: Any]) throws -> [String: Any] {
        var result = settings

        var hooks: [String: Any]
        if let existing = result["hooks"] {
            guard let object = existing as? [String: Any] else {
                throw ShapeError.hooksIsNotAnObject
            }
            hooks = object
        } else {
            hooks = [:]
        }

        for template in templateEntries() {
            var eventArray: [Any]
            if let existing = hooks[template.event] {
                guard let array = existing as? [Any] else {
                    throw ShapeError.eventIsNotAnArray(event: template.event)
                }
                eventArray = array
            } else {
                eventArray = []
            }

            let alreadyPresent = eventArray.contains {
                isOurEntry($0, matcher: template.matcher)
            }
            if !alreadyPresent {
                eventArray.append(template.object)
            }
            hooks[template.event] = eventArray
        }

        result["hooks"] = hooks
        return result
    }

    // MARK: - Reverse filter (uninstall)

    /// Removes our entries per rule 4. Never throws: anything that is not a
    /// shape we could have written is passed through untouched.
    public static func removingOurEntries(from settings: [String: Any]) -> [String: Any] {
        guard let hooksAny = settings["hooks"] else { return settings }
        guard let hooks = hooksAny as? [String: Any] else { return settings }

        var newHooks: [String: Any] = [:]
        for (event, value) in hooks {
            guard let array = value as? [Any] else {
                newHooks[event] = value // not an event array we could have touched
                continue
            }
            var kept: [Any] = []
            for entry in array {
                guard let entryObject = entry as? [String: Any] else {
                    kept.append(entry)
                    continue
                }
                if let cleaned = strippingOurHooks(fromEntry: entryObject) {
                    kept.append(cleaned)
                }
            }
            if !kept.isEmpty {
                newHooks[event] = kept
            }
        }

        var result = settings
        if newHooks.isEmpty {
            result.removeValue(forKey: "hooks")
        } else {
            result["hooks"] = newHooks
        }
        return result
    }

    // MARK: - Integrity / queries (probe support)

    /// True when all seven of our entries are present (matcher-aware for
    /// Notification). This is the same predicate merge uses for idempotence, so
    /// "broken → repair" always converges.
    public static func ourEntriesComplete(in settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return templateEntries().allSatisfy { template in
            guard let array = hooks[template.event] as? [Any] else { return false }
            return array.contains { isOurEntry($0, matcher: template.matcher) }
        }
    }

    /// True when at least one marked entry exists anywhere under `hooks` —
    /// the manifest-lost fallback signal (plan 03 §3.1).
    public static func containsAnyOfOurEntries(_ settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            guard let array = value as? [Any] else { return false }
            return array.contains { entryIsMarked($0) }
        }
    }

    /// The uninstall acceptance contract (rule 5): parsed-level equality via
    /// NSDictionary — order-insensitive, numeric-type tolerant.
    public static func semanticallyEqual(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        NSDictionary(dictionary: a).isEqual(to: b)
    }

    // MARK: - Private helpers

    /// Ours for merge/integrity purposes: marked AND (for Notification) with the
    /// matching `matcher` value.
    private static func isOurEntry(_ entry: Any, matcher: String?) -> Bool {
        guard let object = entry as? [String: Any], entryIsMarked(object) else { return false }
        guard let matcher else { return true }
        return object["matcher"] as? String == matcher
    }

    /// An entry counts as marked when any of its commands contains the marker.
    private static func entryIsMarked(_ entry: Any) -> Bool {
        guard let object = entry as? [String: Any] else { return false }
        if let command = object["command"] as? String, command.contains(markerSubstring) {
            return true
        }
        guard let innerHooks = object["hooks"] as? [Any] else { return false }
        return innerHooks.contains { commandIsMarked($0) }
    }

    private static func commandIsMarked(_ hook: Any) -> Bool {
        guard let object = hook as? [String: Any],
              let command = object["command"] as? String
        else { return false }
        return command.contains(markerSubstring)
    }

    /// Removes our commands from one entry.
    ///
    /// - Entry untouched (nothing of ours inside) → returned as-is.
    /// - Some of our commands removed, user hooks remain → entry with the
    ///   remainder (only ours removed, never the user's).
    /// - Everything inside was ours → `nil` (drop the whole entry).
    private static func strippingOurHooks(fromEntry entry: [String: Any]) -> [String: Any]? {
        // Non-standard flat entry with a marked top-level command → ours, drop.
        if let command = entry["command"] as? String, command.contains(markerSubstring) {
            return nil
        }
        guard let innerHooks = entry["hooks"] as? [Any] else { return entry }

        let kept = innerHooks.filter { !commandIsMarked($0) }
        if kept.count == innerHooks.count {
            return entry // nothing of ours here — keep byte-identical
        }
        if kept.isEmpty {
            return nil // the entry existed only to hold our command(s)
        }
        var cleaned = entry
        cleaned["hooks"] = kept
        return cleaned
    }
}
