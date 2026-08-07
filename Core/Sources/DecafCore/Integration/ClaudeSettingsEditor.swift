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
//    "Application Support/Decaf" identifies our entry; if present, skip.
// 4. Uninstall = reverse filter: drop marked entries everywhere; drop event
//    keys that become empty; drop `hooks` if it becomes empty. "Marked" here
//    also covers the RETIRED marker "Application Support/Caffeinate" — an app
//    that cannot clean up after its former self is worse than one that never
//    installed anything (see `retiredMarkerSubstring`).
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
    public static let markerSubstring = "Application Support/Decaf"

    /// `$BIN` of plan 02 §1.5. `$HOME` stays literal (the shell expands it) and
    /// the value is used only inside double quotes.
    public static let bridgePath = "$HOME/Library/Application Support/Decaf/bin/decaf-bridge"

    /// The quoted base command: `"$HOME/Library/Application Support/Decaf/bin/decaf-bridge"`.
    /// Quotes are part of the command string — mandatory, see header note.
    public static let quotedBridgeCommand = "\"\(bridgePath)\""

    // MARK: - The retired name (2026-08-07 Caffeinate → Decaf rename)

    /// Marker substring identifying entries this app wrote under its FORMER
    /// name, when its App Support directory was `.../Caffeinate` and the bridge
    /// was called `caff-bridge`.
    ///
    /// This constant is permanent, and it is the single most important line in
    /// this file for anyone who ran a pre-rename build. The retired directory no
    /// longer exists, so a hook command still pointing into it fails to exec —
    /// and **Claude Code does not report a hook that fails to exec**. The events
    /// simply stop arriving; the app sees no error, says nothing, and detection
    /// quietly degrades to file activity. Recognising the old marker forever is
    /// the only way the app can say "that entry is mine, and it is dead".
    ///
    /// It is deliberately NOT folded into `entryIsMarked`: merge idempotence and
    /// `integrity(of:)` must treat a retired entry as an *empty* slot, or Repair
    /// would look at a fully occupied `hooks` object and conclude there was
    /// nothing to do.
    public static let retiredMarkerSubstring = "Application Support/Caffeinate"

    /// The bridge's filename under the retired name. `caff-` was an
    /// abbreviation that existed only to keep a PATH-visible executable from
    /// colliding with `/usr/bin/caffeinate` (plan 06 §9); `decaf` has no such
    /// collision, so the abbreviation is gone and the old filename is dead too.
    static let retiredBridgeBinaryName = "caff-bridge"

    /// The bridge's filename today, used when rebuilding a retired command.
    static let bridgeBinaryName = "decaf-bridge"

    /// Fuse timeout for every hook entry (plan 02 §1.5).
    public static let hookTimeout = 5

    /// Events registered without a matcher (plan 02 §1.5).
    ///
    /// `PostToolUse` is the heartbeat (plan 02 §1.1a): the only hook that fires
    /// mid-turn, and the reason `historicalPlainEvents` below exists.
    public static let plainEvents = [
        "SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "StopFailure", "SessionEnd",
    ]

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

    /// Every entry we install: the plain events + the two Notification matchers.
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

    /// True when every entry of the current template is present (matcher-aware
    /// for Notification). This is the same predicate merge uses for
    /// idempotence, so "broken → repair" always converges.
    public static func ourEntriesComplete(in settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return templateEntries().allSatisfy { template in
            guard let array = hooks[template.event] as? [Any] else { return false }
            return array.contains { isOurEntry($0, matcher: template.matcher) }
        }
    }

    /// True when at least one entry of ours exists anywhere under `hooks` —
    /// the manifest-lost fallback signal (plan 03 §3.1).
    ///
    /// Counts the retired name too. This is the question "is there anything of
    /// ours in this file to clean up", and a retired entry is very much ours.
    public static func containsAnyOfOurEntries(_ settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            guard let array = value as? [Any] else { return false }
            return array.contains { entryIsMarked($0) || entryIsRetired($0) }
        }
    }

    // MARK: - Retired-name migration

    /// Every slot currently occupied by an entry written under the retired
    /// product name. Non-empty means the user ran a pre-rename build and their
    /// hooks have been silently dead ever since they upgraded.
    public static func retiredEntryKeys(in settings: [String: Any]) -> Set<EntryKey> {
        guard let hooks = settings["hooks"] as? [String: Any] else { return [] }
        var keys: Set<EntryKey> = []
        for (event, value) in hooks {
            guard let array = value as? [Any] else { continue }
            for candidate in array where entryIsRetired(candidate) {
                let matcher = (candidate as? [String: Any])?["matcher"] as? String
                keys.insert(EntryKey(event: event, matcher: matcher))
            }
        }
        return keys
    }

    /// Rewrites every retired command in place so it points at the current
    /// bridge, leaving the surrounding JSON — including the user's own entries,
    /// key order aside — untouched.
    ///
    /// Rewriting rather than deleting-and-appending is what keeps the user's
    /// file recognisable: the entry stays in the same slot, in the same
    /// position within its event array, with its `timeout` and `matcher` as they
    /// were. Only the command string changes.
    ///
    /// Converges: the output contains no retired command, so a second pass is a
    /// no-op. Returns `settings` unchanged (not merely equal) when there was
    /// nothing to migrate, so callers can treat "unchanged" as "no write
    /// needed".
    public static func migratingRetiredEntries(in settings: [String: Any]) -> [String: Any] {
        guard let hooks = settings["hooks"] as? [String: Any] else { return settings }

        var changed = false
        var newHooks: [String: Any] = [:]
        for (event, value) in hooks {
            guard let array = value as? [Any] else {
                newHooks[event] = value // not an event array we could have written
                continue
            }
            newHooks[event] = array.map { element -> Any in
                guard var object = element as? [String: Any] else { return element }
                if let command = object["command"] as? String,
                   let migrated = migratedCommand(command) {
                    object["command"] = migrated
                    changed = true
                }
                if let innerHooks = object["hooks"] as? [Any] {
                    object["hooks"] = innerHooks.map { hook -> Any in
                        guard var hookObject = hook as? [String: Any],
                              let command = hookObject["command"] as? String,
                              let migrated = migratedCommand(command)
                        else { return hook }
                        hookObject["command"] = migrated
                        changed = true
                        return hookObject
                    }
                }
                return object
            }
        }

        guard changed else { return settings }
        var result = settings
        result["hooks"] = newHooks
        return result
    }

    // MARK: - Installed-set comparison (upgrade detection)

    /// One installed hook slot: the event, plus the argv matcher for the two
    /// `Notification` entries that are only told apart by it.
    public struct EntryKey: Hashable, Sendable, CustomStringConvertible {
        public let event: String
        public let matcher: String?

        public init(event: String, matcher: String? = nil) {
            self.event = event
            self.matcher = matcher
        }

        public var description: String {
            matcher.map { "\(event):\($0)" } ?? event
        }
    }

    /// The set of slots this build installs.
    public static var expectedEntryKeys: Set<EntryKey> {
        Set(templateEntries().map { EntryKey(event: $0.event, matcher: $0.matcher) })
    }

    /// Plain events registered by earlier shipped builds, oldest shape first.
    ///
    /// This list is the only thing that lets `integrity(of:)` say "outdated"
    /// instead of "damaged", and the distinction matters: an outdated install
    /// is our own fault and repairing it is routine, while a damaged one means
    /// something outside the app rewrote the user's file and the Agents pane
    /// should say so in different words. Append here — never edit in place —
    /// whenever `plainEvents` or `notificationMatchers` grows.
    static let historicalPlainEventSets: [[String]] = [
        // v1 (through the MVP): the six turn-boundary events, no heartbeat.
        ["SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "SessionEnd"],
    ]

    /// Full slot sets of earlier shipped builds (the `Notification` pair has
    /// been constant since v1).
    static var historicalEntryKeySets: [Set<EntryKey>] {
        historicalPlainEventSets.map { events in
            Set(
                events.map { EntryKey(event: $0) }
                    + notificationMatchers.map { EntryKey(event: "Notification", matcher: $0) }
            )
        }
    }

    /// Every slot in `settings` currently occupied by one of our entries.
    ///
    /// Matcher-aware, and it reports slots under event names we do not install
    /// too — a marked entry we never wrote is exactly the kind of drift the
    /// caller must not mistake for a stale install.
    public static func installedEntryKeys(in settings: [String: Any]) -> Set<EntryKey> {
        guard let hooks = settings["hooks"] as? [String: Any] else { return [] }
        var keys: Set<EntryKey> = []
        for (event, value) in hooks {
            guard let array = value as? [Any] else { continue }
            for entry in array where entryIsMarked(entry) {
                let matcher = (entry as? [String: Any])?["matcher"] as? String
                keys.insert(EntryKey(event: event, matcher: matcher))
            }
        }
        return keys
    }

    /// How the installed slot set compares with the one this build writes.
    public enum Integrity: Equatable, Sendable {
        /// Every slot we install is occupied. (Extra marked slots do not
        /// demote this: they cannot stop the hooks we need from firing.)
        case complete
        /// Exactly what some earlier shipped build installed, and nothing we
        /// do not recognise — the user upgraded the app but their
        /// settings.json still describes the previous version. Repair is a
        /// plain re-run of `install()`.
        case outdated(missing: [EntryKey])
        /// Incomplete in a shape we never shipped: something other than us
        /// edited the file.
        case damaged(missing: [EntryKey])
        /// At least one slot holds an entry this app wrote under its retired
        /// name (`entries`), whose command points at a path that no longer
        /// exists. `missing` is what the current template still lacks.
        ///
        /// This is not a flavour of `outdated`. An outdated install still
        /// delivers the events it does list; a retired one delivers *nothing*,
        /// while looking complete to any check that counts occupied slots.
        /// Repair is `migratingRetiredEntries` followed by the normal merge.
        case retiredName(entries: [EntryKey], missing: [EntryKey])
        /// None of our entries are present at all.
        case absent
    }

    /// Classifies `settings` against the current template. Read-only.
    public static func integrity(of settings: [String: Any]) -> Integrity {
        // Retired entries are tested FIRST and outrank every other verdict.
        // They occupy the slots, so `installedEntryKeys` alone would call a
        // fully-retired file complete — precisely backwards, since not one of
        // those commands can run. See `retiredMarkerSubstring`.
        let retired = retiredEntryKeys(in: settings)
        if !retired.isEmpty {
            let occupied = installedEntryKeys(in: settings)
            return .retiredName(
                entries: retired.sorted { $0.description < $1.description },
                missing: expectedEntryKeys.subtracting(occupied)
                    .sorted { $0.description < $1.description }
            )
        }

        let installed = installedEntryKeys(in: settings)
        guard !installed.isEmpty else { return .absent }

        let expected = expectedEntryKeys
        if installed.isSuperset(of: expected) { return .complete }

        let missing = expected.subtracting(installed).sorted { $0.description < $1.description }
        // "Outdated" is a strong claim, so it takes two conditions: nothing
        // present beyond what we install today (otherwise the file has been
        // edited by someone else), and everything present that some earlier
        // build installed (otherwise entries have been deleted, which is
        // damage, not age).
        let nothingUnexpected = expected.isSuperset(of: installed)
        let matchesAShippedShape = historicalEntryKeySets.contains { installed.isSuperset(of: $0) }
        if nothingUnexpected && matchesAShippedShape {
            return .outdated(missing: missing)
        }
        return .damaged(missing: missing)
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

    /// Walks the two entry shapes we have ever had to deal with — a flat
    /// top-level `command`, and the standard `hooks: [{command: …}]` array —
    /// and reports whether any command in either satisfies `predicate`.
    ///
    /// Factored out because "is this ours" and "is this ours under the retired
    /// name" must ask the same structural question and differ only in the
    /// string they look for. Two hand-written walks would drift.
    private static func entry(_ entry: Any, hasCommandMatching predicate: (String) -> Bool) -> Bool {
        guard let object = entry as? [String: Any] else { return false }
        if let command = object["command"] as? String, predicate(command) { return true }
        guard let innerHooks = object["hooks"] as? [Any] else { return false }
        return innerHooks.contains { hook in
            guard let hookObject = hook as? [String: Any],
                  let command = hookObject["command"] as? String
            else { return false }
            return predicate(command)
        }
    }

    /// An entry counts as marked when any of its commands contains the marker.
    /// Current name only — see `retiredMarkerSubstring` for why.
    private static func entryIsMarked(_ candidate: Any) -> Bool {
        entry(candidate) { $0.contains(markerSubstring) }
    }

    /// An entry written by this app under its retired name.
    private static func entryIsRetired(_ candidate: Any) -> Bool {
        entry(candidate) { commandIsRetired($0) }
    }

    private static func commandIsRetired(_ command: String) -> Bool {
        command.contains(retiredMarkerSubstring)
    }

    /// Ours under *either* name. Uninstall uses this: an app that cannot clean
    /// up after its former self leaves the retired entries in the user's
    /// settings.json forever, and nothing else will ever recognise them.
    private static func commandIsOurs(_ hook: Any) -> Bool {
        guard let object = hook as? [String: Any],
              let command = object["command"] as? String
        else { return false }
        return command.contains(markerSubstring) || commandIsRetired(command)
    }

    /// The current form of a hook command written under the retired name, or
    /// `nil` when the command is not one of ours-under-the-old-name.
    ///
    /// The path is *rebuilt*, not patched. Swapping the directory alone would
    /// leave the command pointing at `caff-bridge`, a filename that is equally
    /// gone. Everything after the quoted path is carried over verbatim — that
    /// suffix is the `permission_prompt` / `idle_prompt` argv, the only thing
    /// telling the two `Notification` entries apart (plan 02 §1.5).
    static func migratedCommand(_ command: String) -> String? {
        guard commandIsRetired(command) else { return nil }
        if command.hasPrefix("\"") {
            let afterOpening = command.index(after: command.startIndex)
            if let closing = command.range(of: "\"", range: afterOpening..<command.endIndex) {
                return quotedBridgeCommand + String(command[closing.upperBound...])
            }
        }
        // Unquoted variant. Not a shape we ever wrote — the path contains a
        // space, so we have always quoted it — but rewriting it still beats
        // leaving a dead command behind.
        return command
            .replacingOccurrences(of: retiredBridgeBinaryName, with: bridgeBinaryName)
            .replacingOccurrences(of: retiredMarkerSubstring, with: markerSubstring)
    }

    /// Removes our commands from one entry.
    ///
    /// - Entry untouched (nothing of ours inside) → returned as-is.
    /// - Some of our commands removed, user hooks remain → entry with the
    ///   remainder (only ours removed, never the user's).
    /// - Everything inside was ours → `nil` (drop the whole entry).
    private static func strippingOurHooks(fromEntry entry: [String: Any]) -> [String: Any]? {
        // Non-standard flat entry with a marked top-level command → ours, drop.
        if let command = entry["command"] as? String,
           command.contains(markerSubstring) || commandIsRetired(command) {
            return nil
        }
        guard let innerHooks = entry["hooks"] as? [Any] else { return entry }

        let kept = innerHooks.filter { !commandIsOurs($0) }
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
