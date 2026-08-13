// ClaudeCodeIntegration — the MVP installer (plan 03 §3.2/§3.3).
//
// probe:   binary probing (fixed candidate dirs, then a cached `$SHELL -lic`
//          fallback — a GUI app's PATH is just /usr/bin:/bin:/usr/sbin:/sbin),
//          entry integrity in ~/.claude/settings.json, bridge-in-place check.
// install: copy decaf-bridge from the app bundle's Helpers to the fixed App
//          Support landing spot → back up settings.json → deep-merge → atomic
//          write → record in the manifest. Idempotent; repair == re-install.
// uninstall: reverse-filter our entries; delete the file only if we created it
//          and nothing but `{}` remains; manifest record removed.
// refreshBridgeIfNeeded: silent re-copy when the bundled bridge version differs
//          from the installed one (app launch path, decision R4).

import Foundation
import HookWire

// MARK: - Process running

/// Injected process launcher — used only by probe (shell lookup + `--version`).
public protocol ProcessRunning {
    /// Runs `executable` with `arguments`; returns trimmed stdout on exit 0,
    /// or nil on launch failure, non-zero exit, or timeout.
    func runCapturingOutput(executable: String, arguments: [String], timeout: TimeInterval) -> String?
}

/// Real implementation on Foundation.Process. Not exercised in unit tests.
public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func runCapturingOutput(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe() // swallow
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain stdout on a background queue so a chatty child can't deadlock
        // on a full pipe buffer while we wait for it to exit.
        var data = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            data = stdout.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }

        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exited.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 1)
            return nil
        }
        _ = drained.wait(timeout: .now() + 1)

        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - ClaudeCodeIntegration

/// `@unchecked Sendable` on purpose, and it is what makes the app's first launch
/// bearable: `probe()` can cost seconds (a login-shell lookup for anyone using
/// nvm/fnm/volta/asdf, plus `claude --version`), so the app runs it off the main
/// actor and keeps only the published result there. Everything this class owns
/// is either immutable (`fileSystem` / `runner` / `configuration` and the two
/// value-type helpers built from them) or one of the two caches below, which are
/// guarded by `cacheLock`.
public final class ClaudeCodeIntegration: AgentIntegration, @unchecked Sendable {
    /// Everything environment-shaped, injected for testability.
    public struct Configuration {
        /// Absolute home directory (no trailing slash).
        public var homeDirectory: String
        /// Copy source: `Decaf.app/Contents/Helpers/decaf-bridge`.
        public var bundledBridgePath: String
        /// Copy source for the statusline bridge; defaults to the sibling of
        /// `bundledBridgePath` named `decaf-statusline` (plan 09 M3b).
        public var bundledStatuslinePath: String
        /// Version of the bundled bridge; recorded in the manifest and compared
        /// on every app launch for the silent re-copy.
        public var bridgeVersion: String
        /// The user's login shell for the slow-path lookup (`$SHELL`).
        public var shellPath: String
        public var now: () -> Date

        public init(
            homeDirectory: String,
            bundledBridgePath: String,
            bundledStatuslinePath: String? = nil,
            bridgeVersion: String,
            shellPath: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
            now: @escaping () -> Date = Date.init
        ) {
            self.homeDirectory = homeDirectory
            self.bundledBridgePath = bundledBridgePath
            self.bundledStatuslinePath = bundledStatuslinePath
                ?? (bundledBridgePath as NSString).deletingLastPathComponent + "/decaf-statusline"
            self.bridgeVersion = bridgeVersion
            self.shellPath = shellPath
            self.now = now
        }
    }

    /// Timeout for `claude --version` (plan 03 §3.2).
    public static let versionProbeTimeout: TimeInterval = 3
    /// Timeout for the `$SHELL -lic 'command -v claude'` slow path.
    public static let shellLookupTimeout: TimeInterval = 10
    /// Binary name we look for.
    public static let binaryName = "claude"

    private let fileSystem: FileSystem
    private let runner: ProcessRunning
    private let configuration: Configuration
    private let paths: IntegrationPaths
    private let editor: ConfigFileEditor
    private let manifest: InstallManifest

    /// Guards the two caches below. `probe()` is called from a background task
    /// (the app never blocks its main actor on it) and from the settings pane's
    /// own refresh, so the caches must survive concurrent readers.
    private let cacheLock = NSLock()
    /// Cache for the slow shell lookup, valid for this process's lifetime
    /// (plan 03 §3.2). `.some(nil)` = looked up, not found.
    private var cachedShellLookup: String??
    /// `claude --version` per resolved binary path, for this process's lifetime.
    /// The probe runs on every launch and on every visit to the Agents tab; the
    /// version of a binary that has not moved does not change under us, and a
    /// 3-second fuse paid on every visit is a cost with nothing bought.
    /// `.some(nil)` = probed, unparseable.
    private var cachedVersions: [String: String?] = [:]

    public init(
        fileSystem: FileSystem,
        processRunner: ProcessRunning,
        configuration: Configuration
    ) {
        self.fileSystem = fileSystem
        self.runner = processRunner
        self.configuration = configuration
        self.paths = IntegrationPaths(homeDirectory: configuration.homeDirectory)
        self.editor = ConfigFileEditor(
            fileSystem: fileSystem,
            backupsDirectory: paths.backupsDirectory,
            now: configuration.now
        )
        self.manifest = InstallManifest(fileSystem: fileSystem, path: paths.manifestFile)
    }

    public var id: AgentKind { .claudeCode }

    // MARK: - Probe (read-only)

    public func probe() -> IntegrationStatus {
        guard let binaryPath = locateBinary() else { return .notDetected }

        // Invalid/unreadable settings count as "our entries are not there";
        // probe never throws and never writes.
        let settings = (try? editor.readJSONObject(atPath: paths.claudeSettingsFile)) ?? nil

        let bridgeInPlace = fileSystem.fileExists(atPath: paths.bridgeBinary)
        let record = manifest.record(for: .claudeCode)
        // Manifest-lost fallback (plan 03 §3.1): our markers alone still
        // identify the install, so the mode is known even without a record.
        let mode = record?.mode ?? .claudeHooks

        switch settings.map(ClaudeSettingsEditor.integrity(of:)) ?? .absent {
        case .complete:
            return bridgeInPlace
                ? .installed(mode)
                : .broken(mode, .bridgeMissing)
        case .outdated:
            // The user upgraded Decaf; their settings.json still lists the
            // previous build's event set. The Agents pane offers Repair — we do
            // not silently rewrite a file the user owns.
            return .broken(mode, .entriesOutdated)
        case .retiredName:
            // Entries from before the Caffeinate → Decaf rename. Every one of
            // them invokes a path that is gone, and a hook that fails to exec
            // is silent, so this must never be reported as an install however
            // complete the slot coverage looks. Repair migrates them.
            return .broken(mode, .entriesFromRetiredName)
        case .damaged:
            return .broken(mode, .entriesMissing)
        case .absent:
            if let record {
                // Manifest says installed but every entry is gone.
                return .broken(record.mode, .entriesMissing)
            }
            return .detected(version: probeVersion(binaryPath: binaryPath))
        }
    }

    // MARK: - Planned changes (consent-dialog data)

    public func plannedChanges() -> [PlannedChange] {
        var changes: [PlannedChange] = []

        changes.append(
            PlannedChange(
                path: paths.bridgeBinary,
                kind: fileSystem.fileExists(atPath: paths.bridgeBinary) ? .modify : .create,
                preview: "Copy of the decaf-bridge helper (v\(configuration.bridgeVersion)) "
                    + "from the Decaf app bundle. Hook commands point here so they "
                    + "keep working if the app is moved."
            )
        )

        let settingsExist = fileSystem.fileExists(atPath: paths.claudeSettingsFile)
        changes.append(
            PlannedChange(
                path: paths.claudeSettingsFile,
                kind: settingsExist ? .modify : .create,
                preview: hooksFragmentPreview()
            )
        )
        return changes
    }

    private func hooksFragmentPreview() -> String {
        let fragment = ClaudeSettingsEditor.hooksFragment()
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: fragment,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ),
            let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }

    // MARK: - Install (idempotent)

    public func install() throws -> InstallRecord {
        // Parse first: an invalid settings.json aborts the whole install with
        // every file untouched (plan 03 §3.1 write discipline).
        let existingSettings = try editor.readJSONObject(atPath: paths.claudeSettingsFile)
        // Migrate before merging. Entries written under the retired name occupy
        // the slots we are about to fill; rewriting their command in place
        // repairs them without appending a second, duplicate set beside the
        // dead one. Merge then sees the migrated entries as already present and
        // stays idempotent. A no-op when there is nothing from the old name.
        let migrated = ClaudeSettingsEditor.migratingRetiredEntries(in: existingSettings ?? [:])
        let merged = try ClaudeSettingsEditor.merge(ourEntriesInto: migrated)

        // 1. Bridge: bundle Helpers → fixed App Support landing spot.
        guard fileSystem.fileExists(atPath: configuration.bundledBridgePath) else {
            throw IntegrationError.bundledBridgeMissing(path: configuration.bundledBridgePath)
        }
        try fileSystem.createDirectory(atPath: paths.binDirectory)
        let bridgeExisted = fileSystem.fileExists(atPath: paths.bridgeBinary)
        try fileSystem.copyItem(atPath: configuration.bundledBridgePath, toPath: paths.bridgeBinary)

        // 2. Backup (rotating, latest kept) — only when there is a file to back up.
        var backups: [String: String] = [:]
        let settingsExisted = existingSettings != nil
        if settingsExisted {
            backups[paths.claudeSettingsFile] = try editor.backUp(fileAtPath: paths.claudeSettingsFile)
        }

        // 3. Merge result → atomic write.
        try fileSystem.createDirectory(atPath: paths.claudeConfigDirectory)
        try editor.writeJSONObject(merged, toPath: paths.claudeSettingsFile)

        // 4. Manifest. "Created by us" survives re-install/repair: if a previous
        //    record created the file, it is still ours to delete on uninstall.
        let previous = manifest.record(for: .claudeCode)
        var createdFiles: [String] = []
        if !settingsExisted || previous?.createdFiles.contains(paths.claudeSettingsFile) == true {
            createdFiles.append(paths.claudeSettingsFile)
        }
        if !bridgeExisted || previous?.createdFiles.contains(paths.bridgeBinary) == true {
            createdFiles.append(paths.bridgeBinary)
        }
        let record = InstallRecord(
            agent: .claudeCode,
            mode: .claudeHooks,
            touchedFiles: [paths.bridgeBinary, paths.claudeSettingsFile],
            backups: backups,
            bridgeVersion: configuration.bridgeVersion,
            installedAt: configuration.now(),
            createdFiles: createdFiles
        )
        try manifest.upsert(record)
        return record
    }

    // MARK: - Uninstall

    public func uninstall(_ record: InstallRecord) throws {
        let settingsPath = paths.claudeSettingsFile

        // Invalid JSON aborts (never "fix it up"); a missing file just means
        // there is nothing to filter.
        if let settings = try editor.readJSONObject(atPath: settingsPath) {
            _ = try editor.backUp(fileAtPath: settingsPath)
            let cleaned = ClaudeSettingsEditor.removingOurEntries(from: settings)
            if cleaned.isEmpty, record.createdFiles.contains(settingsPath) {
                // We created the file and only `{}` would remain (rule 4).
                try fileSystem.removeItem(atPath: settingsPath)
            } else {
                try editor.writeJSONObject(cleaned, toPath: settingsPath)
            }
        }

        try manifest.removeRecord(for: .claudeCode)

        // The App Support bridge copy is ours; drop it once no integration
        // references it any more (MVP: manifest empty == no references).
        if manifest.load().isEmpty, fileSystem.fileExists(atPath: paths.bridgeBinary) {
            try? fileSystem.removeItem(atPath: paths.bridgeBinary)
        }
    }

    /// Convenience for the app shell (assembly seam): uninstall using the
    /// manifest's record, or — when the manifest was lost but our markers
    /// remain — a synthetic record that filters entries without deleting files.
    public func uninstall() throws {
        let record = manifest.record(for: .claudeCode) ?? InstallRecord(
            agent: .claudeCode,
            mode: .claudeHooks,
            touchedFiles: [paths.claudeSettingsFile],
            backups: [:],
            bridgeVersion: configuration.bridgeVersion,
            installedAt: configuration.now(),
            createdFiles: []
        )
        try uninstall(record)
    }

    // MARK: - Statusline bridge (plan 09 M3b)

    /// Deliberately NOT recorded in the install manifest: the `statusLine`
    /// slot is self-describing (marker-based `isOurs`), the chain sidecar is
    /// the only extra state, and widening `InstallRecord`'s schema would force
    /// a manifest migration for a feature the file can answer on its own.

    /// True when settings.json's statusLine slot holds our command.
    public func statuslineInstalled() -> Bool {
        let settings = (try? editor.readJSONObject(atPath: paths.claudeSettingsFile)) ?? nil
        return settings.map(StatuslineSettingsEditor.isOurs) ?? false
    }

    public func plannedStatuslineChanges() -> [PlannedChange] {
        [
            PlannedChange(
                path: paths.statuslineBinary,
                kind: fileSystem.fileExists(atPath: paths.statuslineBinary) ? .modify : .create,
                preview: "Copy of the decaf-statusline helper from the Decaf app bundle. "
                    + "Claude Code's status line runs it; it reads the official rate-limit "
                    + "numbers and passes your existing status line through unchanged."
            ),
            PlannedChange(
                path: paths.claudeSettingsFile,
                kind: fileSystem.fileExists(atPath: paths.claudeSettingsFile) ? .modify : .create,
                preview: "statusLine → \(StatuslineSettingsEditor.quotedCommand) "
                    + "(your current statusLine, if any, is preserved and chained to)"
            ),
        ]
    }

    /// Install: copy the binary, swap the statusLine slot, persist the chain
    /// sidecar. Same write discipline as hooks: parse first, abort untouched
    /// on invalid JSON, rotating backup before the write.
    public func installStatusline() throws {
        let existingSettings = try editor.readJSONObject(atPath: paths.claudeSettingsFile)

        guard fileSystem.fileExists(atPath: configuration.bundledStatuslinePath) else {
            throw IntegrationError.bundledBridgeMissing(path: configuration.bundledStatuslinePath)
        }
        try fileSystem.createDirectory(atPath: paths.binDirectory)
        try fileSystem.copyItem(atPath: configuration.bundledStatuslinePath, toPath: paths.statuslineBinary)

        let result = StatuslineSettingsEditor.install(into: existingSettings ?? [:])

        // The sidecar first, so a crash between the two writes leaves a chain
        // file with no consumer (harmless) rather than our command with no
        // chain (the user's statusline goes dark). Never overwrite a captured
        // chain with nothing: a re-install over our own entry captures nil.
        if let captured = result.capturedPrevious {
            try editor.writeJSONObject(
                StatuslineSettingsEditor.chainFilePayload(previous: captured),
                toPath: paths.statuslineChainFile
            )
        } else if !fileSystem.fileExists(atPath: paths.statuslineChainFile) {
            try editor.writeJSONObject(
                StatuslineSettingsEditor.chainFilePayload(previous: nil),
                toPath: paths.statuslineChainFile
            )
        }

        if existingSettings != nil {
            _ = try editor.backUp(fileAtPath: paths.claudeSettingsFile)
        }
        try fileSystem.createDirectory(atPath: paths.claudeConfigDirectory)
        try editor.writeJSONObject(result.settings, toPath: paths.claudeSettingsFile)
    }

    /// Uninstall: restore the chained statusline (or drop the key), remove the
    /// sidecar and the binary. A foreign statusLine is never touched.
    public func uninstallStatusline() throws {
        if let settings = try editor.readJSONObject(atPath: paths.claudeSettingsFile),
           StatuslineSettingsEditor.isOurs(settings) {
            let previous = (try? editor.readJSONObject(atPath: paths.statuslineChainFile))
                .flatMap { $0?["previous"] as? [String: Any] }
            _ = try editor.backUp(fileAtPath: paths.claudeSettingsFile)
            let restored = StatuslineSettingsEditor.uninstall(from: settings, restoring: previous)
            try editor.writeJSONObject(restored, toPath: paths.claudeSettingsFile)
        }
        if fileSystem.fileExists(atPath: paths.statuslineChainFile) {
            try? fileSystem.removeItem(atPath: paths.statuslineChainFile)
        }
        if fileSystem.fileExists(atPath: paths.statuslineBinary) {
            try? fileSystem.removeItem(atPath: paths.statuslineBinary)
        }
    }

    // MARK: - Bridge version upkeep (app-launch path)

    /// Compares the bundled bridge version with the installed one and silently
    /// re-copies on mismatch (or when the copy vanished), updating the manifest
    /// (plan 03 §3.1 / decision R4). No-op when nothing is installed.
    /// Returns true when a re-copy happened.
    @discardableResult
    public func refreshBridgeIfNeeded() throws -> Bool {
        guard var record = manifest.record(for: .claudeCode) else { return false }
        let copyMissing = !fileSystem.fileExists(atPath: paths.bridgeBinary)
        guard copyMissing || record.bridgeVersion != configuration.bridgeVersion else {
            return false
        }
        guard fileSystem.fileExists(atPath: configuration.bundledBridgePath) else {
            throw IntegrationError.bundledBridgeMissing(path: configuration.bundledBridgePath)
        }
        try fileSystem.createDirectory(atPath: paths.binDirectory)
        try fileSystem.copyItem(atPath: configuration.bundledBridgePath, toPath: paths.bridgeBinary)
        record.bridgeVersion = configuration.bridgeVersion
        try manifest.upsert(record)
        return true
    }

    // MARK: - Binary probing (plan 03 §3.2)

    /// Fixed candidate directories checked before falling back to the login
    /// shell. Order matters only for speed; any hit wins.
    ///
    /// The list is long on purpose. Every directory missing from it is a user
    /// whose probe falls through to `$SHELL -lic` — ten seconds of a login shell
    /// sourcing their whole profile, plus three more for `--version`. The
    /// version managers below (volta, asdf, mise, fnm, nvm, pnpm, yarn, deno)
    /// are exactly the population that used to pay that, and `~/.claude/local/bin`
    /// is where Claude Code's own installer puts the binary.
    var candidateDirectories: [String] {
        let home = configuration.homeDirectory
        var directories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            // Claude Code's own local install location.
            home + "/.claude/local/bin",
            home + "/.local/bin",
            home + "/.cargo/bin",
            home + "/.bun/bin",
            home + "/.npm-global/bin",
            // Node version managers with a fixed shim directory.
            home + "/.volta/bin",
            home + "/.asdf/shims",
            home + "/.local/share/mise/shims",
            home + "/.fnm/aliases/default/bin",
            home + "/Library/pnpm",
            home + "/.yarn/bin",
            home + "/.deno/bin",
        ]
        // nvm has no shim directory: every installed Node version owns its own
        // bin. Newest first, since that is where a global install of a current
        // tool lives. A missing ~/.nvm just yields nothing.
        let nvmVersions = home + "/.nvm/versions/node"
        let installed = (try? fileSystem.contentsOfDirectory(atPath: nvmVersions)) ?? []
        directories.append(
            contentsOf: installed
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { nvmVersions + "/" + $0 + "/bin" }
        )
        return directories
    }

    private func locateBinary() -> String? {
        for directory in candidateDirectories {
            let candidate = directory + "/" + Self.binaryName
            if fileSystem.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        // Slow path: interactive login shell, so the user's PATH tweaks apply.
        // Result (including "not found") is cached for the process lifetime.
        cacheLock.lock()
        let cached = cachedShellLookup
        cacheLock.unlock()
        if let cached { return cached }

        let output = runner.runCapturingOutput(
            executable: configuration.shellPath,
            arguments: ["-lic", "command -v \(Self.binaryName)"],
            timeout: Self.shellLookupTimeout
        )
        let path = output?
            .split(separator: "\n")
            .last
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        let resolved = (path?.hasPrefix("/") == true) ? path : nil
        cacheLock.lock()
        cachedShellLookup = .some(resolved)
        cacheLock.unlock()
        return resolved
    }

    /// `claude --version` with a 3s fuse; any parse failure → nil ("version
    /// unknown", plan 03 §3.2). Cached per binary path for the process lifetime.
    private func probeVersion(binaryPath: String) -> String? {
        cacheLock.lock()
        let cached = cachedVersions[binaryPath]
        cacheLock.unlock()
        if let cached { return cached }

        let output = runner.runCapturingOutput(
            executable: binaryPath,
            arguments: ["--version"],
            timeout: Self.versionProbeTimeout
        )
        let version = output.flatMap(Self.parseVersion(from:))
        cacheLock.lock()
        cachedVersions[binaryPath] = .some(version)
        cacheLock.unlock()
        return version
    }

    /// Extracts the first semver-looking token (e.g. "2.1.37" out of
    /// "2.1.37 (Claude Code)").
    static func parseVersion(from output: String) -> String? {
        let pattern = #"[0-9]+\.[0-9]+(\.[0-9]+)?"#
        guard let range = output.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return String(output[range])
    }
}
