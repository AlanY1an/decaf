// AgentIntegration — installer-framework contract (plan 03 §3.1/§3.2).
//
// Agent identity reuses HookWire.AgentKind (review decision R14: one AgentKind,
// no separate AgentID). All installers are pure logic over an injected
// `FileSystem` (defined in ConfigFileEditor.swift) so every path is unit-testable
// without touching the real home directory.

import Foundation
import HookWire

/// How a given agent's integration is wired up (plan 03 §3.1).
public enum IntegrationMode: String, Codable, Equatable, Sendable {
    /// Claude Code via `~/.claude/settings.json` hooks (MVP).
    case claudeHooks
    /// User installed the marketplace plugin; the local installer steps aside (V1.x).
    case claudePlugin
    /// Codex >= 0.144 native hooks (V1.x).
    case codexNativeHooks
    /// Codex < 0.144 `notify` fallback — turn-end signal only (V1.x).
    case codexNotifyFallback
    /// opencode single-file plugin (V1.x).
    case opencodePlugin
}

/// Why an installed integration is currently broken (plan 03 §3.1).
public enum BrokenReason: String, Codable, Equatable, Sendable {
    /// Our entries vanished from the config file (overwritten by user/agent).
    case entriesMissing
    /// Our entries are intact but describe an older version of Decaf: the
    /// app now registers hooks this install does not have (plan 02 §1.1a added
    /// `PostToolUse`). Nobody damaged anything — the app moved and the config
    /// did not follow, which is why it is a separate reason from
    /// `entriesMissing`: the same Repair button, a different sentence above it,
    /// and no implication that the user's editor is to blame. Repair is the
    /// normal idempotent `install()`; we never rewrite the file behind the
    /// user's back.
    case entriesOutdated
    /// Entries left behind by this app under its FORMER name: their command
    /// points into `~/Library/Application Support/Caffeinate`, the directory the
    /// 2026-08-07 Caffeinate → Decaf rename retired.
    ///
    /// Kept apart from `entriesOutdated` because the two differ in the one way
    /// that matters to detection: an outdated entry set still delivers the
    /// events it lists, while every one of these fails to exec and delivers
    /// nothing. Worse, it does so **silently** — Claude Code does not report a
    /// hook that fails to exec, so without this reason the app would show a
    /// healthy install while running on file activity alone. Repair rewrites
    /// the commands in place; Uninstall Hooks removes them.
    case entriesFromRetiredName
    /// The bridge binary is not at its expected App Support location.
    case bridgeMissing
    /// Codex only: hooks.json changed but `[hooks.state]` hash did not follow.
    case trustHashMismatch
    /// Codex only: the single `notify` slot is occupied by another command.
    case notifyConflict
}

/// Result of a side-effect-free `probe()` (plan 03 §3.1/§3.2).
public enum IntegrationStatus: Equatable, Sendable {
    /// The agent binary was not found on this machine.
    case notDetected
    /// Agent present, our hooks not installed. `version` is nil when
    /// `--version` failed or its output could not be parsed.
    case detected(version: String?)
    /// Entries intact and bridge in place.
    case installed(IntegrationMode)
    /// Something drifted; repair == re-run `install()` (idempotent).
    case broken(IntegrationMode, BrokenReason)
}

/// One file the installer is about to create or modify — the data source for the
/// consent dialog (UI owned by plan 04 step 6; see plan 03 §3.6, decision R12).
public struct PlannedChange: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case create, modify }

    /// Absolute path of the file that will be created/modified.
    public var path: String
    public var kind: Kind
    /// Human-readable preview of what will be written, shown expandable in the dialog.
    public var preview: String

    public init(path: String, kind: Kind, preview: String) {
        self.path = path
        self.kind = kind
        self.preview = preview
    }
}

/// What one `install()` actually did; persisted in the manifest
/// (`integrations.json`) and required by `uninstall(_:)` (plan 03 §3.1).
public struct InstallRecord: Codable, Equatable, Sendable {
    public var agent: AgentKind
    public var mode: IntegrationMode
    /// Every file we created or modified.
    public var touchedFiles: [String]
    /// Original file path → backup file path.
    public var backups: [String: String]
    /// Version of the bridge binary copied to App Support at install time.
    public var bridgeVersion: String
    public var installedAt: Date
    /// Subset of `touchedFiles` that did not exist before we wrote them
    /// (plan 03 §3.3 rule 4: "manifest kind == .create" — uninstall may delete
    /// such a file outright when only `{}` would remain).
    public var createdFiles: [String]

    public init(
        agent: AgentKind,
        mode: IntegrationMode,
        touchedFiles: [String],
        backups: [String: String],
        bridgeVersion: String,
        installedAt: Date,
        createdFiles: [String] = []
    ) {
        self.agent = agent
        self.mode = mode
        self.touchedFiles = touchedFiles
        self.backups = backups
        self.bridgeVersion = bridgeVersion
        self.installedAt = installedAt
        self.createdFiles = createdFiles
    }

    // Tolerate manifests written before `createdFiles` existed.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = try container.decode(AgentKind.self, forKey: .agent)
        mode = try container.decode(IntegrationMode.self, forKey: .mode)
        touchedFiles = try container.decode([String].self, forKey: .touchedFiles)
        backups = try container.decode([String: String].self, forKey: .backups)
        bridgeVersion = try container.decode(String.self, forKey: .bridgeVersion)
        installedAt = try container.decode(Date.self, forKey: .installedAt)
        createdFiles = try container.decodeIfPresent([String].self, forKey: .createdFiles) ?? []
    }
}

/// Common contract for every agent installer (plan 03 §3.1).
///
/// V2 extension point: user-defined agents plug in by conforming to this
/// protocol — no configuration UI exists yet (plan 03 non-goals).
public protocol AgentIntegration {
    var id: AgentKind { get }
    /// Side-effect-free probe: is the agent present, which version, are our
    /// entries intact, is the bridge in place.
    func probe() -> IntegrationStatus
    /// Data source for the (unskippable) consent dialog.
    func plannedChanges() -> [PlannedChange]
    /// Idempotent install: calling twice never produces duplicate entries.
    func install() throws -> InstallRecord
    /// Removes only our entries, driven by `record` + content markers; never
    /// touches anything the user owns.
    func uninstall(_ record: InstallRecord) throws
}

/// Failures specific to the installer layer (file-level failures surface as
/// `ConfigFileError` or the injected `FileSystem`'s own errors).
public enum IntegrationError: Error, Equatable {
    /// The copy source `Decaf.app/Contents/Helpers/decaf-bridge` is missing.
    case bundledBridgeMissing(path: String)
}

/// Well-known absolute paths derived from a home directory (injected so tests
/// can point everything at a sandbox). App Support dir name is "Decaf";
/// the bridge landing spot is fixed (plan 03 §3.1 / decision R4): user configs
/// always point at the App Support copy, never inside the app bundle.
public struct IntegrationPaths: Equatable, Sendable {
    /// Absolute home directory path (no trailing slash).
    public let homeDirectory: String

    public init(homeDirectory: String) {
        self.homeDirectory = homeDirectory
    }

    public var appSupportDirectory: String { homeDirectory + "/Library/Application Support/Decaf" }
    public var binDirectory: String { appSupportDirectory + "/bin" }
    public var bridgeBinary: String { binDirectory + "/decaf-bridge" }
    public var statuslineBinary: String { binDirectory + "/decaf-statusline" }
    /// The chain sidecar decaf-statusline reads (plan 09 M2/M3).
    public var statuslineChainFile: String { appSupportDirectory + "/statusline-chain.json" }
    public var backupsDirectory: String { appSupportDirectory + "/backups" }
    public var manifestFile: String { appSupportDirectory + "/integrations.json" }
    public var claudeConfigDirectory: String { homeDirectory + "/.claude" }
    public var claudeSettingsFile: String { claudeConfigDirectory + "/settings.json" }
}
