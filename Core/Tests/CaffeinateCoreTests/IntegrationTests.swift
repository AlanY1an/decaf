// IntegrationTests — installer framework + Claude Code installer (plan 03
// steps 1–3). Covers the step-2 golden-test list, the uninstall(install(x))
// semantic-equality property (plan 03 §3.3 rule 5), manifest corruption,
// backup rotation, and the probe state matrix (§3.2).
//
// All file IO runs against an in-memory FileSystem; nothing here touches the
// real home directory. Property fixtures avoid the two spec-decreed semantic
// boundaries: pre-existing marked entries (idempotence would eat them) and
// empty event arrays under `hooks` (rule 4 drops keys that become empty).

import Foundation
import Testing
@testable import CaffeinateCore
import HookWire

// MARK: - Test doubles

/// Dictionary-backed FileSystem. Enforces "parent directory must exist" on
/// writes so missing createDirectory calls fail loudly in tests.
private final class InMemoryIntegrationFS: FileSystem {
    enum FSError: Error { case missing(String), noParentDirectory(String) }

    private(set) var files: [String: Data] = [:]
    private(set) var directories: Set<String> = ["/"]
    private(set) var executables: Set<String> = []

    func addDirectory(_ path: String) {
        var current = path
        while current != "/", !current.isEmpty {
            directories.insert(current)
            current = (current as NSString).deletingLastPathComponent
        }
    }

    func addFile(_ path: String, _ data: Data, executable: Bool = false) {
        addDirectory((path as NSString).deletingLastPathComponent)
        files[path] = data
        if executable { executables.insert(path) }
    }

    // FileSystem

    func fileExists(atPath path: String) -> Bool {
        files[path] != nil || directories.contains(path)
    }

    func isExecutableFile(atPath path: String) -> Bool {
        files[path] != nil && executables.contains(path)
    }

    func readData(atPath path: String) throws -> Data {
        guard let data = files[path] else { throw FSError.missing(path) }
        return data
    }

    func writeDataAtomically(_ data: Data, toPath path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        guard directories.contains(parent) else { throw FSError.noParentDirectory(parent) }
        files[path] = data
    }

    func copyItem(atPath sourcePath: String, toPath destinationPath: String) throws {
        guard let data = files[sourcePath] else { throw FSError.missing(sourcePath) }
        let parent = (destinationPath as NSString).deletingLastPathComponent
        guard directories.contains(parent) else { throw FSError.noParentDirectory(parent) }
        files[destinationPath] = data
        if executables.contains(sourcePath) { executables.insert(destinationPath) }
    }

    func removeItem(atPath path: String) throws {
        if files.removeValue(forKey: path) != nil {
            executables.remove(path)
            return
        }
        guard directories.contains(path) else { throw FSError.missing(path) }
        let prefix = path + "/"
        directories = directories.filter { $0 != path && !$0.hasPrefix(prefix) }
        for key in files.keys where key.hasPrefix(prefix) {
            files.removeValue(forKey: key)
            executables.remove(key)
        }
    }

    func createDirectory(atPath path: String) throws {
        addDirectory(path)
    }

    func contentsOfDirectory(atPath path: String) throws -> [String] {
        guard directories.contains(path) else { throw FSError.missing(path) }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        var names: Set<String> = []
        for key in files.keys where key.hasPrefix(prefix) {
            if let first = key.dropFirst(prefix.count).split(separator: "/").first {
                names.insert(String(first))
            }
        }
        for dir in directories where dir.hasPrefix(prefix) {
            if let first = dir.dropFirst(prefix.count).split(separator: "/").first {
                names.insert(String(first))
            }
        }
        return Array(names)
    }
}

private final class IntegrationStubRunner: ProcessRunning {
    var handler: (String, [String]) -> String? = { _, _ in nil }
    private(set) var calls: [(executable: String, arguments: [String])] = []

    func runCapturingOutput(executable: String, arguments: [String], timeout: TimeInterval) -> String? {
        calls.append((executable, arguments))
        return handler(executable, arguments)
    }

    var shellLookupCallCount: Int {
        calls.filter { $0.arguments.first == "-lic" }.count
    }
}

private final class DateBox {
    var date = Date(timeIntervalSince1970: 1_754_300_000)
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

/// One fully wired ClaudeCodeIntegration over the in-memory world.
private struct Harness {
    let fs = InMemoryIntegrationFS()
    let runner = IntegrationStubRunner()
    let clock = DateBox()
    let paths = IntegrationPaths(homeDirectory: "/Users/tester")
    let bundledBridgePath = "/Applications/Caffeinate.app/Contents/Helpers/caff-bridge"

    init(claudeInstalled: Bool = true, bundledBridge: Bool = true, bridgeVersion: String = "1.0.0") {
        if bundledBridge {
            fs.addFile(bundledBridgePath, Data("bridge-\(bridgeVersion)".utf8), executable: true)
        }
        if claudeInstalled {
            fs.addFile("/opt/homebrew/bin/claude", Data("claude".utf8), executable: true)
        }
        runner.handler = { _, arguments in
            arguments == ["--version"] ? "2.1.37 (Claude Code)" : nil
        }
    }

    func makeIntegration(bridgeVersion: String = "1.0.0") -> ClaudeCodeIntegration {
        let box = clock
        return ClaudeCodeIntegration(
            fileSystem: fs,
            processRunner: runner,
            configuration: .init(
                homeDirectory: paths.homeDirectory,
                bundledBridgePath: bundledBridgePath,
                bridgeVersion: bridgeVersion,
                shellPath: "/bin/zsh",
                now: { box.date }
            )
        )
    }

    func writeSettings(_ text: String) {
        fs.addFile(paths.claudeSettingsFile, Data(text.utf8))
    }

    func settingsObject() throws -> [String: Any] {
        let data = try fs.readData(atPath: paths.claudeSettingsFile)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

// MARK: - JSON helpers

private func jsonObject(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

private func eventArray(_ settings: [String: Any], _ event: String) -> [Any] {
    ((settings["hooks"] as? [String: Any])?[event] as? [Any]) ?? []
}

// MARK: - Deterministic fixture generator (property test)

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func randomSettings(using rng: inout SeededGenerator) -> [String: Any] {
    var settings: [String: Any] = [:]
    for key in ["model", "env", "permissions", "statusLine", "alwaysThinkingEnabled"]
    where Bool.random(using: &rng) {
        settings[key] = randomValue(depth: 0, using: &rng)
    }
    if Bool.random(using: &rng) {
        var hooks: [String: Any] = [:]
        for event in ["Stop", "Notification", "PreToolUse", "SessionStart", "WeirdFutureEvent"]
        where Bool.random(using: &rng) {
            hooks[event] = (0..<Int.random(in: 1...2, using: &rng)).map { _ in
                randomUserEntry(using: &rng)
            }
        }
        if !hooks.isEmpty { settings["hooks"] = hooks }
    }
    return settings
}

private func randomUserEntry(using rng: inout SeededGenerator) -> [String: Any] {
    var entry: [String: Any] = [:]
    if Bool.random(using: &rng) {
        entry["matcher"] = ["Bash", "permission_prompt", "*"].randomElement(using: &rng)!
    }
    let commands = ["echo hi", "/usr/local/bin/notify --now", "~/bin/thing --flag"]
    let hook: [String: Any] = [
        "type": "command",
        "command": commands.randomElement(using: &rng)!,
        "timeout": Int.random(in: 1...60, using: &rng),
    ]
    var inner: [Any] = [hook]
    if Bool.random(using: &rng) {
        inner.append(["type": "command", "command": "say done"] as [String: Any])
    }
    entry["hooks"] = inner
    if Bool.random(using: &rng) { entry["userField"] = true }
    return entry
}

private func randomValue(depth: Int, using rng: inout SeededGenerator) -> Any {
    switch Int.random(in: 0...(depth < 2 ? 5 : 3), using: &rng) {
    case 0: return "string-\(Int.random(in: 0...99, using: &rng))"
    case 1: return Int.random(in: -5...100, using: &rng)
    case 2: return Bool.random(using: &rng)
    case 3: return 3.5
    case 4:
        return (0..<Int.random(in: 1...3, using: &rng)).map { _ in
            randomValue(depth: depth + 1, using: &rng)
        }
    default:
        var object: [String: Any] = [:]
        for key in ["a", "b", "c"].prefix(Int.random(in: 1...3, using: &rng)) {
            object[key] = randomValue(depth: depth + 1, using: &rng)
        }
        return object
    }
}

// MARK: - Tests

@Suite struct IntegrationTests {
    // MARK: ClaudeSettingsEditor golden tests (plan 03 step 2)

    @Suite struct ClaudeSettingsEditorGolden {
        @Test func commandTemplateIsQuotedHomeRelativeWithArgvMatchers() {
            // Plan 02 §1.5 verbatim; the quotes are load-bearing ("Application
            // Support" contains a space, hooks run through /bin/sh).
            #expect(
                ClaudeSettingsEditor.quotedBridgeCommand
                    == "\"$HOME/Library/Application Support/Caffeinate/bin/caff-bridge\""
            )
            #expect(ClaudeSettingsEditor.quotedBridgeCommand.hasPrefix("\""))
            #expect(ClaudeSettingsEditor.quotedBridgeCommand.hasSuffix("\""))
            #expect(!ClaudeSettingsEditor.bridgePath.contains("/Users/"))
            #expect(ClaudeSettingsEditor.hookTimeout == 5)

            let notification = ClaudeSettingsEditor.templateEntries().filter { $0.event == "Notification" }
            #expect(notification.map(\.matcher) == ["permission_prompt", "idle_prompt"])
            let commands = notification.map { entry -> String in
                let inner = entry.object["hooks"] as? [[String: Any]] ?? []
                return inner.first?["command"] as? String ?? ""
            }
            #expect(commands == [
                "\"$HOME/Library/Application Support/Caffeinate/bin/caff-bridge\" permission_prompt",
                "\"$HOME/Library/Application Support/Caffeinate/bin/caff-bridge\" idle_prompt",
            ])
        }

        @Test func mergeIntoEmptySettingsCreatesAllEntries() throws {
            // "Empty file" golden: an empty settings.json parses to [:].
            let merged = try ClaudeSettingsEditor.merge(ourEntriesInto: [:])
            let hooks = try #require(merged["hooks"] as? [String: Any])
            #expect(Set(hooks.keys) == Set(ClaudeSettingsEditor.plainEvents + ["Notification"]))
            for event in ClaudeSettingsEditor.plainEvents {
                let array = try #require(hooks[event] as? [Any])
                #expect(array.count == 1)
                let entry = try #require(array.first as? [String: Any])
                let inner = try #require(entry["hooks"] as? [[String: Any]])
                #expect(inner.first?["type"] as? String == "command")
                #expect(inner.first?["command"] as? String == ClaudeSettingsEditor.quotedBridgeCommand)
                #expect(inner.first?["timeout"] as? Int == 5)
                #expect(entry["matcher"] == nil)
            }
            #expect(ClaudeSettingsEditor.ourEntriesComplete(in: merged))
        }

        @Test func mergePreservesSettingsWithoutHooksKey() throws {
            let original = try jsonObject(#"{"model": "opus", "alwaysThinkingEnabled": true}"#)
            let merged = try ClaudeSettingsEditor.merge(ourEntriesInto: original)
            #expect(merged["model"] as? String == "opus")
            #expect(merged["alwaysThinkingEnabled"] as? Bool == true)
            #expect(ClaudeSettingsEditor.ourEntriesComplete(in: merged))
        }

        @Test func mergePreservesUserEntriesInSameEvents() throws {
            let original = try jsonObject(#"""
            {
              "hooks": {
                "Stop": [
                  { "hooks": [ { "type": "command", "command": "echo user-stop", "timeout": 30 } ] }
                ],
                "Notification": [
                  { "matcher": "permission_prompt",
                    "hooks": [ { "type": "command", "command": "say ding" } ] }
                ]
              }
            }
            """#)
            let merged = try ClaudeSettingsEditor.merge(ourEntriesInto: original)

            // User entry stays first and byte-identical; ours is appended.
            let stop = eventArray(merged, "Stop")
            #expect(stop.count == 2)
            let firstStop = try #require(stop.first as? [String: Any])
            let userHook = try #require((firstStop["hooks"] as? [[String: Any]])?.first)
            #expect(userHook["command"] as? String == "echo user-stop")
            #expect(userHook["timeout"] as? Int == 30)

            // The user's own permission_prompt entry is not ours (no marker),
            // so both of our Notification entries still get appended.
            let notification = eventArray(merged, "Notification")
            #expect(notification.count == 3)
            #expect(ClaudeSettingsEditor.ourEntriesComplete(in: merged))
        }

        @Test func mergeIsIdempotent() throws {
            let original = try jsonObject(#"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo hi"}]}]}}"#)
            let once = try ClaudeSettingsEditor.merge(ourEntriesInto: original)
            let twice = try ClaudeSettingsEditor.merge(ourEntriesInto: once)
            #expect(ClaudeSettingsEditor.semanticallyEqual(once, twice))
            #expect(eventArray(twice, "Stop").count == 2)
            #expect(eventArray(twice, "Notification").count == 2)
        }

        @Test func unknownFieldsPassThrough() throws {
            let original = try jsonObject(#"""
            {
              "futureTopLevel": { "nested": [1, 2, {"deep": true}] },
              "hooks": {
                "SomeFutureEvent": [
                  { "matcher": "X", "unknownEntryField": 42,
                    "hooks": [ { "type": "command", "command": "echo x", "futureHookField": "keep" } ] }
                ]
              }
            }
            """#)
            let merged = try ClaudeSettingsEditor.merge(ourEntriesInto: original)
            let mergedDict = NSDictionary(dictionary: merged)
            #expect(mergedDict["futureTopLevel"] != nil)

            let future = eventArray(merged, "SomeFutureEvent")
            let entry = try #require(future.first as? [String: Any])
            #expect(entry["unknownEntryField"] as? Int == 42)
            let inner = try #require((entry["hooks"] as? [[String: Any]])?.first)
            #expect(inner["futureHookField"] as? String == "keep")

            // Reverse filter hands the unknown material back untouched.
            let removed = ClaudeSettingsEditor.removingOurEntries(from: merged)
            #expect(ClaudeSettingsEditor.semanticallyEqual(removed, original))
        }

        @Test func notificationDoubleMatcher() throws {
            let merged = try ClaudeSettingsEditor.merge(ourEntriesInto: [:])
            let notification = eventArray(merged, "Notification")
            #expect(notification.count == 2)
            let entries = notification.compactMap { $0 as? [String: Any] }
            #expect(entries.map { $0["matcher"] as? String } == ["permission_prompt", "idle_prompt"])
            for entry in entries {
                let matcher = try #require(entry["matcher"] as? String)
                let inner = try #require((entry["hooks"] as? [[String: Any]])?.first)
                let command = try #require(inner["command"] as? String)
                #expect(command.hasSuffix(" " + matcher), "matcher travels via argv (plan 02 §1.5)")
                #expect(command.hasPrefix("\""), "path stays quoted before the argv matcher")
            }
        }

        @Test func mergeThrowsOnImpossibleShapes() throws {
            let hooksNotObject = try jsonObject(#"{"hooks": "nope"}"#)
            #expect(throws: ClaudeSettingsEditor.ShapeError.hooksIsNotAnObject) {
                _ = try ClaudeSettingsEditor.merge(ourEntriesInto: hooksNotObject)
            }
            let eventNotArray = try jsonObject(#"{"hooks": {"Stop": {"oops": true}}}"#)
            #expect(throws: ClaudeSettingsEditor.ShapeError.eventIsNotAnArray(event: "Stop")) {
                _ = try ClaudeSettingsEditor.merge(ourEntriesInto: eventNotArray)
            }
        }

        @Test func reverseFilterDropsEmptyEventAndHooksKeys() throws {
            // Rule 4: arrays emptied by our removal drop their event key, an
            // emptied hooks object drops the hooks key.
            let merged = try ClaudeSettingsEditor.merge(ourEntriesInto: [:])
            let removed = ClaudeSettingsEditor.removingOurEntries(from: merged)
            #expect(removed.isEmpty)
            #expect(removed["hooks"] == nil)
        }

        @Test func reverseFilterKeepsUserHookSharingAnEntryWithOurs() throws {
            // Hand-merged pathological case: the user's command and ours inside
            // one entry's inner hooks array. Only ours is removed.
            let mixed = try jsonObject(#"""
            {
              "hooks": {
                "Stop": [
                  { "hooks": [
                      { "type": "command", "command": "echo user" },
                      { "type": "command", "command": "\"$HOME/Library/Application Support/Caffeinate/bin/caff-bridge\"", "timeout": 5 }
                  ] }
                ]
              }
            }
            """#)
            let removed = ClaudeSettingsEditor.removingOurEntries(from: mixed)
            let stop = eventArray(removed, "Stop")
            #expect(stop.count == 1)
            let inner = try #require((stop.first as? [String: Any])?["hooks"] as? [[String: Any]])
            #expect(inner.count == 1)
            #expect(inner.first?["command"] as? String == "echo user")
        }

        @Test func propertyUninstallOfInstallIsSemanticIdentity() throws {
            // Plan 03 acceptance: on arbitrary fixtures, uninstall(install(x))
            // parses semantically equal to x (NSDictionary equality — never
            // byte equality, §3.3 rule 5).
            var rng = SeededGenerator(seed: 0xCAFF_E1AE)
            for iteration in 0..<80 {
                let fixture = randomSettings(using: &rng)
                let installed = try ClaudeSettingsEditor.merge(ourEntriesInto: fixture)
                let uninstalled = ClaudeSettingsEditor.removingOurEntries(from: installed)
                #expect(
                    ClaudeSettingsEditor.semanticallyEqual(uninstalled, fixture),
                    "round-trip mismatch on seeded fixture #\(iteration)"
                )
            }
        }
    }

    // MARK: ConfigFileEditor + manifest (plan 03 step 1)

    @Suite struct ConfigFileEditing {
        @Test func emptyAndWhitespaceFilesReadAsEmptyObject() throws {
            let fs = InMemoryIntegrationFS()
            fs.addFile("/u/settings.json", Data())
            fs.addFile("/u/blank.json", Data("  \n\t".utf8))
            let editor = ConfigFileEditor(fileSystem: fs, backupsDirectory: "/u/backups")
            #expect(try editor.readJSONObject(atPath: "/u/settings.json")?.isEmpty == true)
            #expect(try editor.readJSONObject(atPath: "/u/blank.json")?.isEmpty == true)
            #expect(try editor.readJSONObject(atPath: "/u/missing.json") == nil)
        }

        @Test func invalidJSONAndNonObjectRootsThrow() throws {
            let fs = InMemoryIntegrationFS()
            fs.addFile("/u/bad.json", Data("{not json".utf8))
            fs.addFile("/u/array.json", Data("[1, 2]".utf8))
            let editor = ConfigFileEditor(fileSystem: fs, backupsDirectory: "/u/backups")
            #expect(throws: ConfigFileError.invalidJSON(path: "/u/bad.json")) {
                _ = try editor.readJSONObject(atPath: "/u/bad.json")
            }
            #expect(throws: ConfigFileError.notAnObject(path: "/u/array.json")) {
                _ = try editor.readJSONObject(atPath: "/u/array.json")
            }
        }

        @Test func backupRotationKeepsOnlyTheLatest() throws {
            let fs = InMemoryIntegrationFS()
            fs.addFile("/u/.claude/settings.json", Data("v1".utf8))
            let clock = DateBox()
            let editor = ConfigFileEditor(
                fileSystem: fs,
                backupsDirectory: "/u/backups",
                now: { clock.date }
            )

            let first = try editor.backUp(fileAtPath: "/u/.claude/settings.json")
            #expect(fs.files[first] == Data("v1".utf8))

            fs.addFile("/u/.claude/settings.json", Data("v2".utf8))
            clock.advance(61)
            let second = try editor.backUp(fileAtPath: "/u/.claude/settings.json")

            let entries = try fs.contentsOfDirectory(atPath: "/u/backups")
            #expect(entries.count == 1, "only the most recent backup per file survives")
            #expect(entries.first == (second as NSString).lastPathComponent)
            #expect(fs.files[second] == Data("v2".utf8))
            #expect(fs.files[first] == nil)
        }

        @Test func manifestSurvivesMissingAndCorruptFiles() throws {
            let fs = InMemoryIntegrationFS()
            let manifest = InstallManifest(fileSystem: fs, path: "/u/as/integrations.json")
            #expect(manifest.load().isEmpty)

            fs.addFile("/u/as/integrations.json", Data("###corrupt###".utf8))
            #expect(manifest.load().isEmpty, "corrupt manifest degrades to empty, never throws")

            let record = InstallRecord(
                agent: .claudeCode,
                mode: .claudeHooks,
                touchedFiles: ["/u/.claude/settings.json"],
                backups: [:],
                bridgeVersion: "1.0.0",
                installedAt: Date(timeIntervalSince1970: 1_754_300_000),
                createdFiles: ["/u/.claude/settings.json"]
            )
            try manifest.upsert(record)
            #expect(manifest.record(for: .claudeCode) == record)

            var updated = record
            updated.bridgeVersion = "1.1.0"
            try manifest.upsert(updated)
            #expect(manifest.load().count == 1, "upsert replaces per agent")
            #expect(manifest.record(for: .claudeCode)?.bridgeVersion == "1.1.0")

            try manifest.removeRecord(for: .claudeCode)
            #expect(manifest.load().isEmpty)
        }

        @Test func defaultFileSystemWritesAtomicallyWithoutLeftovers() throws {
            // Real-FS check of the atomic-write discipline, in an isolated temp
            // directory (never the user's home).
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("caffeinate-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let fs = DefaultFileSystem()
            let target = root.appendingPathComponent("settings.json").path
            try fs.writeDataAtomically(Data("first".utf8), toPath: target)
            try fs.writeDataAtomically(Data("second".utf8), toPath: target)
            #expect(try fs.readData(atPath: target) == Data("second".utf8))
            let leftovers = try fs.contentsOfDirectory(atPath: root.path)
            #expect(leftovers == ["settings.json"], "no temp files survive a completed write")

            // Interrupted path: unreachable destination throws and leaves nothing.
            let missingParent = root.appendingPathComponent("nope/deep.json").path
            #expect(throws: (any Error).self) {
                try fs.writeDataAtomically(Data("x".utf8), toPath: missingParent)
            }
            #expect(!fs.fileExists(atPath: missingParent))
        }
    }

    // MARK: ClaudeCodeIntegration probe/install/uninstall (plan 03 step 3)

    @Suite struct ClaudeCodeIntegrationFlow {
        @Test func probeNotDetectedWithoutBinary() {
            let harness = Harness(claudeInstalled: false)
            #expect(harness.makeIntegration().probe() == .notDetected)
        }

        @Test func probeDetectedParsesVersion() {
            let harness = Harness()
            #expect(harness.makeIntegration().probe() == .detected(version: "2.1.37"))
        }

        @Test func probeVersionUnknownOnGarbageOutput() {
            let harness = Harness()
            harness.runner.handler = { _, arguments in
                arguments == ["--version"] ? "no digits here" : nil
            }
            #expect(harness.makeIntegration().probe() == .detected(version: nil))
        }

        @Test func probeShellFallbackIsUsedAndCachedPerProcess() {
            let harness = Harness(claudeInstalled: false)
            harness.runner.handler = { executable, arguments in
                if arguments.first == "-lic" {
                    #expect(executable == "/bin/zsh")
                    #expect(arguments == ["-lic", "command -v claude"])
                    return "/weird/place/bin/claude"
                }
                if arguments == ["--version"] { return "Claude Code version 2.0.9" }
                return nil
            }
            let integration = harness.makeIntegration()
            #expect(integration.probe() == .detected(version: "2.0.9"))
            #expect(integration.probe() == .detected(version: "2.0.9"))
            #expect(harness.runner.shellLookupCallCount == 1, "slow path cached for process lifetime")
        }

        @Test func installCreatesBridgeSettingsAndManifest() throws {
            let harness = Harness()
            let integration = harness.makeIntegration()
            let record = try integration.install()

            #expect(harness.fs.files[harness.paths.bridgeBinary] == Data("bridge-1.0.0".utf8))
            let settings = try harness.settingsObject()
            #expect(ClaudeSettingsEditor.ourEntriesComplete(in: settings))

            #expect(record.agent == .claudeCode)
            #expect(record.mode == .claudeHooks)
            #expect(record.touchedFiles.contains(harness.paths.claudeSettingsFile))
            #expect(record.touchedFiles.contains(harness.paths.bridgeBinary))
            #expect(record.bridgeVersion == "1.0.0")
            #expect(record.backups.isEmpty, "nothing existed, nothing to back up")
            #expect(record.createdFiles.contains(harness.paths.claudeSettingsFile))

            let manifest = InstallManifest(fileSystem: harness.fs, path: harness.paths.manifestFile)
            #expect(manifest.record(for: .claudeCode) == record)
            #expect(integration.probe() == .installed(.claudeHooks))
        }

        @Test func installBacksUpAndPreservesUserSettings() throws {
            let harness = Harness()
            let originalText = #"{"model": "opus", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo user"}]}]}}"#
            harness.writeSettings(originalText)
            let original = try jsonObject(originalText)

            let record = try harness.makeIntegration().install()

            let backupPath = try #require(record.backups[harness.paths.claudeSettingsFile])
            #expect(harness.fs.files[backupPath] == Data(originalText.utf8), "backup is the pre-edit bytes")
            #expect(!record.createdFiles.contains(harness.paths.claudeSettingsFile))

            let merged = try harness.settingsObject()
            #expect(merged["model"] as? String == "opus")
            #expect(eventArray(merged, "Stop").count == 2)
            #expect(ClaudeSettingsEditor.semanticallyEqual(
                ClaudeSettingsEditor.removingOurEntries(from: merged), original
            ))
        }

        @Test func installTwiceProducesIdenticalFileContent() throws {
            let harness = Harness()
            harness.writeSettings(#"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo user"}]}]}}"#)
            let integration = harness.makeIntegration()

            _ = try integration.install()
            let afterFirst = harness.fs.files[harness.paths.claudeSettingsFile]
            harness.clock.advance(90)
            _ = try integration.install()
            let afterSecond = harness.fs.files[harness.paths.claudeSettingsFile]

            #expect(afterFirst == afterSecond, "idempotent: second install changes nothing")
            let backups = try harness.fs.contentsOfDirectory(atPath: harness.paths.backupsDirectory)
            #expect(backups.count == 1, "backup rotation across repeated installs")
        }

        @Test func installAbortsUntouchedOnInvalidJSON() throws {
            let harness = Harness()
            let corrupt = "{definitely not json"
            harness.writeSettings(corrupt)
            let integration = harness.makeIntegration()

            #expect(throws: ConfigFileError.invalidJSON(path: harness.paths.claudeSettingsFile)) {
                _ = try integration.install()
            }
            #expect(harness.fs.files[harness.paths.claudeSettingsFile] == Data(corrupt.utf8),
                    "invalid settings.json is left byte-for-byte untouched")
            #expect(harness.fs.files[harness.paths.bridgeBinary] == nil,
                    "abort happens before any side effect")
            let manifest = InstallManifest(fileSystem: harness.fs, path: harness.paths.manifestFile)
            #expect(manifest.load().isEmpty)
        }

        @Test func probeReportsEntriesMissingAfterExternalWipe() throws {
            let harness = Harness()
            let integration = harness.makeIntegration()
            _ = try integration.install()

            harness.writeSettings("{}") // Claude Code rewrote the file over us
            #expect(integration.probe() == .broken(.claudeHooks, .entriesMissing))

            // Repair == re-run install (idempotent), back to installed.
            harness.clock.advance(30)
            _ = try integration.install()
            #expect(integration.probe() == .installed(.claudeHooks))
        }

        @Test func probeReportsBridgeMissing() throws {
            let harness = Harness()
            let integration = harness.makeIntegration()
            _ = try integration.install()
            try harness.fs.removeItem(atPath: harness.paths.bridgeBinary)
            #expect(integration.probe() == .broken(.claudeHooks, .bridgeMissing))
        }

        @Test func probeFallsBackToMarkersWhenManifestIsLost() throws {
            let harness = Harness()
            let integration = harness.makeIntegration()
            _ = try integration.install()
            try harness.fs.removeItem(atPath: harness.paths.manifestFile)
            // Wipe one event so the entries are incomplete but markers remain.
            var settings = try harness.settingsObject()
            var hooks = try #require(settings["hooks"] as? [String: Any])
            hooks.removeValue(forKey: "Stop")
            settings["hooks"] = hooks
            let data = try JSONSerialization.data(withJSONObject: settings)
            harness.fs.addFile(harness.paths.claudeSettingsFile, data)

            #expect(integration.probe() == .broken(.claudeHooks, .entriesMissing))
        }

        @Test func uninstallRestoresUserSettingsSemantically() throws {
            let harness = Harness()
            let originalText = #"""
            {"model": "opus",
             "hooks": {
               "Stop": [{"hooks": [{"type": "command", "command": "echo user"}]}],
               "Notification": [{"matcher": "permission_prompt", "hooks": [{"type": "command", "command": "say ding"}]}]
             }}
            """#
            harness.writeSettings(originalText)
            let original = try jsonObject(originalText)
            let integration = harness.makeIntegration()

            let record = try integration.install()
            harness.clock.advance(120)
            try integration.uninstall(record)

            let after = try harness.settingsObject()
            #expect(ClaudeSettingsEditor.semanticallyEqual(after, original),
                    "uninstall(install(x)) is semantically x")
            let manifest = InstallManifest(fileSystem: harness.fs, path: harness.paths.manifestFile)
            #expect(manifest.load().isEmpty)
            #expect(harness.fs.files[harness.paths.bridgeBinary] == nil,
                    "last integration gone → bridge copy removed")
            #expect(integration.probe() == .detected(version: "2.1.37"))
        }

        @Test func uninstallDeletesTheFileOnlyIfWeCreatedIt() throws {
            let harness = Harness()
            let integration = harness.makeIntegration()
            let record = try integration.install() // no settings.json existed
            harness.clock.advance(60)
            try integration.uninstall(record)
            #expect(harness.fs.files[harness.paths.claudeSettingsFile] == nil,
                    "we created it and only {} remained → file removed (rule 4)")
        }

        @Test func uninstallKeepsAFileWeCreatedOnceUserAddedContent() throws {
            let harness = Harness()
            let integration = harness.makeIntegration()
            let record = try integration.install()

            // User adds their own key to the file we created.
            var settings = try harness.settingsObject()
            settings["model"] = "opus"
            let data = try JSONSerialization.data(withJSONObject: settings)
            harness.fs.addFile(harness.paths.claudeSettingsFile, data)

            harness.clock.advance(60)
            try integration.uninstall(record)
            let after = try harness.settingsObject()
            #expect(after["model"] as? String == "opus")
            #expect(after["hooks"] == nil)
        }

        @Test func refreshBridgeRecopiesOnVersionMismatch() throws {
            let harness = Harness()
            _ = try harness.makeIntegration().install()

            // App update ships bridge 1.1.0.
            harness.fs.addFile(harness.bundledBridgePath, Data("bridge-1.1.0".utf8), executable: true)
            let updated = harness.makeIntegration(bridgeVersion: "1.1.0")

            #expect(try updated.refreshBridgeIfNeeded() == true)
            #expect(harness.fs.files[harness.paths.bridgeBinary] == Data("bridge-1.1.0".utf8))
            let manifest = InstallManifest(fileSystem: harness.fs, path: harness.paths.manifestFile)
            #expect(manifest.record(for: .claudeCode)?.bridgeVersion == "1.1.0")
            #expect(try updated.refreshBridgeIfNeeded() == false, "second call is a no-op")
        }

        @Test func refreshBridgeRestoresADeletedCopy() throws {
            let harness = Harness()
            let integration = harness.makeIntegration()
            _ = try integration.install()
            try harness.fs.removeItem(atPath: harness.paths.bridgeBinary)
            #expect(try integration.refreshBridgeIfNeeded() == true)
            #expect(harness.fs.files[harness.paths.bridgeBinary] == Data("bridge-1.0.0".utf8))
        }

        @Test func refreshBridgeIsNoopWhenNothingInstalled() throws {
            let harness = Harness()
            #expect(try harness.makeIntegration().refreshBridgeIfNeeded() == false)
        }

        @Test func plannedChangesListBothFilesWithPreviews() throws {
            let harness = Harness()
            let integration = harness.makeIntegration()

            let fresh = integration.plannedChanges()
            #expect(fresh.map(\.path) == [harness.paths.bridgeBinary, harness.paths.claudeSettingsFile])
            #expect(fresh.map(\.kind) == [.create, .create])
            let settingsPreview = try #require(fresh.last?.preview)
            #expect(settingsPreview.contains("Application Support/Caffeinate"))
            #expect(settingsPreview.contains("permission_prompt"))
            #expect(settingsPreview.contains("idle_prompt"))
            #expect(settingsPreview.contains("SessionStart"))

            harness.writeSettings("{}")
            let existing = integration.plannedChanges()
            #expect(existing.last?.kind == .modify)
        }

        @Test func installRequiresTheBundledBridge() throws {
            let harness = Harness(bundledBridge: false)
            #expect(throws: IntegrationError.bundledBridgeMissing(path: harness.bundledBridgePath)) {
                _ = try harness.makeIntegration().install()
            }
        }
    }

    // MARK: - Hook-set upgrades (plan 02 §1.5 / plan 03 §3.3)

    /// The event set grows between releases (`PostToolUse`, plan 02 §1.1a), so
    /// "our entries are present" stopped being the same question as "our
    /// entries are current". These tests fence the difference: an install that
    /// is merely OLD must be named as old, repaired idempotently, and must
    /// never be rewritten behind the user's back.
    @Suite struct HookSetUpgrade {

        /// Exactly what a pre-heartbeat Caffeinate wrote, with the user's own
        /// configuration around it. Byte-shaped on purpose: this is the file
        /// sitting on an already-installed machine right now.
        static let legacySettingsJSON = #"""
        {
          "model": "opus",
          "hooks": {
            "SessionStart": [ { "hooks": [ { "type": "command", "command": "\"$HOME/Library/Application Support/Caffeinate/bin/caff-bridge\"", "timeout": 5 } ] } ],
            "UserPromptSubmit": [ { "hooks": [ { "type": "command", "command": "\"$HOME/Library/Application Support/Caffeinate/bin/caff-bridge\"", "timeout": 5 } ] } ],
            "Stop": [
              { "hooks": [ { "type": "command", "command": "echo user-stop", "timeout": 30 } ] },
              { "hooks": [ { "type": "command", "command": "\"$HOME/Library/Application Support/Caffeinate/bin/caff-bridge\"", "timeout": 5 } ] }
            ],
            "StopFailure": [ { "hooks": [ { "type": "command", "command": "\"$HOME/Library/Application Support/Caffeinate/bin/caff-bridge\"", "timeout": 5 } ] } ],
            "SessionEnd": [ { "hooks": [ { "type": "command", "command": "\"$HOME/Library/Application Support/Caffeinate/bin/caff-bridge\"", "timeout": 5 } ] } ],
            "Notification": [
              { "matcher": "permission_prompt", "hooks": [ { "type": "command", "command": "\"$HOME/Library/Application Support/Caffeinate/bin/caff-bridge\" permission_prompt", "timeout": 5 } ] },
              { "matcher": "idle_prompt", "hooks": [ { "type": "command", "command": "\"$HOME/Library/Application Support/Caffeinate/bin/caff-bridge\" idle_prompt", "timeout": 5 } ] }
            ],
            "PreToolUse": [
              { "matcher": "Bash", "hooks": [ { "type": "command", "command": "~/bin/audit-bash.sh" } ] }
            ]
          }
        }
        """#

        /// What `legacySettingsJSON` reduces to once every Caffeinate entry —
        /// v1's and the heartbeat we add on repair — has been filtered out.
        static let userOnlySettingsJSON = #"""
        {
          "model": "opus",
          "hooks": {
            "Stop": [
              { "hooks": [ { "type": "command", "command": "echo user-stop", "timeout": 30 } ] }
            ],
            "PreToolUse": [
              { "matcher": "Bash", "hooks": [ { "type": "command", "command": "~/bin/audit-bash.sh" } ] }
            ]
          }
        }
        """#

        @Test func currentTemplateRegistersTheHeartbeatWithoutAnArgvMatcher() throws {
            #expect(ClaudeSettingsEditor.plainEvents.contains("PostToolUse"))
            let heartbeat = try #require(
                ClaudeSettingsEditor.templateEntries().first { $0.event == "PostToolUse" }
            )
            #expect(heartbeat.matcher == nil, "the heartbeat is told apart by hook_event_name (plan 02 §1.5)")
            #expect(heartbeat.object["matcher"] == nil)
            let inner = try #require(heartbeat.object["hooks"] as? [[String: Any]])
            #expect(inner.first?["command"] as? String == ClaudeSettingsEditor.quotedBridgeCommand,
                    "same bridge command as every other event")
            #expect(inner.first?["timeout"] as? Int == 5)
        }

        @Test func historicalSetsAreAppendOnlyAndPredateTheHeartbeat() {
            // If this list is ever edited rather than appended to, every user
            // on the edited version starts being reported as "damaged".
            for set in ClaudeSettingsEditor.historicalPlainEventSets {
                #expect(!set.contains("PostToolUse"))
                #expect(Set(set).isSubset(of: Set(ClaudeSettingsEditor.plainEvents)))
            }
            #expect(ClaudeSettingsEditor.historicalPlainEventSets.contains(
                ["SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "SessionEnd"]
            ))
        }

        @Test func integrityClassifiesTheFourShapes() throws {
            #expect(ClaudeSettingsEditor.integrity(of: [:]) == .absent)
            #expect(ClaudeSettingsEditor.integrity(of: try jsonObject(#"{"model":"opus"}"#)) == .absent)

            let current = try ClaudeSettingsEditor.merge(ourEntriesInto: [:])
            #expect(ClaudeSettingsEditor.integrity(of: current) == .complete)

            let legacy = try jsonObject(Self.legacySettingsJSON)
            #expect(
                ClaudeSettingsEditor.integrity(of: legacy)
                    == .outdated(missing: [ClaudeSettingsEditor.EntryKey(event: "PostToolUse")])
            )

            // Damage: an event a shipped build always installed is gone, so the
            // shape is one we never wrote.
            var damaged = current
            var hooks = try #require(damaged["hooks"] as? [String: Any])
            hooks.removeValue(forKey: "SessionEnd")
            damaged["hooks"] = hooks
            guard case .damaged(let missing) = ClaudeSettingsEditor.integrity(of: damaged) else {
                Issue.record("expected .damaged, got \(ClaudeSettingsEditor.integrity(of: damaged))")
                return
            }
            #expect(missing == [ClaudeSettingsEditor.EntryKey(event: "SessionEnd")])
        }

        @Test func aMarkedEntryWeNeverWriteIsDamageNotAge() throws {
            // Everything a v1 build installed is present, but there is also one
            // of our commands under an event we do not register — the file has
            // been edited by something other than this app.
            var legacy = try jsonObject(Self.legacySettingsJSON)
            var hooks = try #require(legacy["hooks"] as? [String: Any])
            hooks["PreCompact"] = [
                ["hooks": [["type": "command", "command": ClaudeSettingsEditor.quotedBridgeCommand]]]
            ]
            legacy["hooks"] = hooks
            guard case .damaged = ClaudeSettingsEditor.integrity(of: legacy) else {
                Issue.record("a marked entry outside the template must not read as merely outdated")
                return
            }
        }

        @Test func installedEntryKeysAreMatcherAwareAndIgnoreUserEntries() throws {
            let legacy = try jsonObject(Self.legacySettingsJSON)
            let keys = ClaudeSettingsEditor.installedEntryKeys(in: legacy)
            #expect(keys.contains(ClaudeSettingsEditor.EntryKey(event: "Notification", matcher: "permission_prompt")))
            #expect(keys.contains(ClaudeSettingsEditor.EntryKey(event: "Notification", matcher: "idle_prompt")))
            #expect(!keys.contains(ClaudeSettingsEditor.EntryKey(event: "PostToolUse")))
            // The user's own Stop hook and their PreToolUse audit hook are not
            // ours and must not appear.
            #expect(!keys.contains(ClaudeSettingsEditor.EntryKey(event: "PreToolUse", matcher: "Bash")))
            #expect(keys.count == ClaudeSettingsEditor.expectedEntryKeys.count - 1)
        }

        /// The golden end-to-end: an already-installed old-shape settings.json
        /// is reported as outdated, repaired by the ordinary idempotent
        /// install, and everything the user owns survives byte-for-byte.
        @Test func outdatedInstallIsDetectedAndRepairedWithoutDisturbingUserEntries() throws {
            let harness = Harness()
            harness.writeSettings(Self.legacySettingsJSON)
            let original = try jsonObject(Self.legacySettingsJSON)
            let integration = harness.makeIntegration()

            // A machine that installed with the previous build also has a
            // manifest record from it.
            let manifest = InstallManifest(fileSystem: harness.fs, path: harness.paths.manifestFile)
            try manifest.upsert(
                InstallRecord(
                    agent: .claudeCode,
                    mode: .claudeHooks,
                    touchedFiles: [harness.paths.bridgeBinary, harness.paths.claudeSettingsFile],
                    backups: [:],
                    bridgeVersion: "1.0.0",
                    installedAt: harness.clock.date,
                    createdFiles: []
                )
            )
            harness.fs.addFile(harness.paths.bridgeBinary, Data("bridge-1.0.0".utf8), executable: true)

            #expect(integration.probe() == .broken(.claudeHooks, .entriesOutdated),
                    "an old event set is outdated, not damaged")
            #expect(harness.fs.files[harness.paths.claudeSettingsFile] == Data(Self.legacySettingsJSON.utf8),
                    "probe is read-only: no silent rewrite of the user's config")

            // Repair == the ordinary install.
            harness.clock.advance(60)
            _ = try integration.install()
            #expect(integration.probe() == .installed(.claudeHooks))

            let repaired = try harness.settingsObject()
            // Exactly one entry added, and it is ours.
            #expect(eventArray(repaired, "PostToolUse").count == 1)
            let added = try #require(eventArray(repaired, "PostToolUse").first as? [String: Any])
            let addedHook = try #require((added["hooks"] as? [[String: Any]])?.first)
            #expect(addedHook["command"] as? String == ClaudeSettingsEditor.quotedBridgeCommand)
            #expect(added["matcher"] == nil)

            // Nothing the user owns moved.
            #expect(repaired["model"] as? String == "opus")
            #expect(ClaudeSettingsEditor.semanticallyEqual(
                ["hooks": ["PreToolUse": eventArray(repaired, "PreToolUse")]],
                ["hooks": ["PreToolUse": eventArray(original, "PreToolUse")]]
            ))
            let stop = eventArray(repaired, "Stop")
            #expect(stop.count == 2, "no duplicate of our Stop entry")
            let userStop = try #require(stop.first as? [String: Any])
            #expect((userStop["hooks"] as? [[String: Any]])?.first?["command"] as? String == "echo user-stop")

            // Repair is idempotent: a second pass changes not one byte.
            let afterRepair = harness.fs.files[harness.paths.claudeSettingsFile]
            harness.clock.advance(60)
            _ = try integration.install()
            #expect(harness.fs.files[harness.paths.claudeSettingsFile] == afterRepair)

            // And uninstall still lands on the user's own configuration: the
            // reverse filter must clear the entries v1 wrote AND the one this
            // build added, leaving nothing of ours behind.
            harness.clock.advance(60)
            try integration.uninstall()
            let cleaned = try harness.settingsObject()
            #expect(ClaudeSettingsEditor.semanticallyEqual(cleaned, try jsonObject(Self.userOnlySettingsJSON)),
                    "uninstall removes the entries we added across BOTH versions and nothing else")
            #expect(ClaudeSettingsEditor.integrity(of: cleaned) == .absent)
        }

        @Test func outdatedIsReportedEvenWhenTheManifestIsLost() throws {
            let harness = Harness()
            harness.writeSettings(Self.legacySettingsJSON)
            harness.fs.addFile(harness.paths.bridgeBinary, Data("bridge-1.0.0".utf8), executable: true)
            // No manifest record at all: our markers alone must still be enough
            // to tell "old" from "someone else edited this".
            #expect(harness.makeIntegration().probe() == .broken(.claudeHooks, .entriesOutdated))
        }
    }
}
