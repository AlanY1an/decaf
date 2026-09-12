import Foundation
import AppKit
import SwiftUI
import DecafCore
import SessionTransfer
import SessionMigration

/// Synthetic input to the real Sessions page. No user accounts or conversations
/// are read. The window is rendered offscreen and never ordered on screen.
@MainActor
func renderSessionSamples() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("decaf-session-render-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let paths = SessionPaths(desktop: root.appendingPathComponent("desktop"),
                                 claude: root.appendingPathComponent("cli"), logs: root.appendingPathComponent("logs"))
        let oldAccount = "e84294ab-0000-4000-8000-000000000000", current = "a1879cf2-0000-4000-8000-000000000000"
        let studio = "f94294ab-0000-4000-8000-000000000000"
        let organization = "83729adc-0000-4000-8000-000000000000"
        let destination = DesktopAccount(accountID: current, organizationID: organization)
        let sourceFolder = paths.desktop.appendingPathComponent("claude-code-sessions/\(oldAccount)/\(organization)")
        let studioFolder = paths.desktop.appendingPathComponent("claude-code-sessions/\(studio)/\(organization)")
        let targetFolder = paths.desktop.appendingPathComponent("claude-code-sessions/\(current)/\(organization)")
        let project = paths.claude.appendingPathComponent("projects/sample-project")
        let cwd = root.appendingPathComponent("Decaf")
        for directory in [sourceFolder, studioFolder, targetFolder, project, cwd, paths.logs, paths.claude.appendingPathComponent("sessions")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        func object(_ data: [String: Any], at url: URL) throws {
            try JSONSerialization.data(withJSONObject: data).write(to: url)
        }
        try object(["lastKnownAccountUuid": current], at: paths.desktop.appendingPathComponent("config.json"))
        try object(["oauthAccount": ["accountUuid": current, "organizationUuid": organization,
                                    "emailAddress": "you@home.com", "organizationName": "Personal"]], at: paths.profile)
        try object(["oauthAccount": ["accountUuid": oldAccount, "organizationUuid": organization,
                                    "emailAddress": "you@work.com", "organizationName": "Acme Inc."]],
                   at: paths.profile.deletingLastPathComponent().appendingPathComponent(".claude.json.backup"))
        try object(["oauthAccount": ["accountUuid": studio, "organizationUuid": organization,
                                    "emailAddress": "you@studio.com", "organizationName": "Studio"]],
                   at: paths.profile.deletingLastPathComponent().appendingPathComponent(".claude.json.backup.1"))
        let now = Date(), formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(formatter.string(from: now.addingTimeInterval(-10))) [info] [LocalSessionManager] Initialization succeeded — accountId=\(destination.accountID), orgId=\(destination.organizationID), existingSessions=0\n"
        try Data(line.utf8).write(to: paths.logs.appendingPathComponent("main.log"))
        let runtime = DesktopRuntime(pid: 100, launchedAt: now.addingTimeInterval(-60), version: SessionCatalog.testedDesktopVersion)
        let titles = ["Polish the little details", "Build the monthly usage view", "A calmer settings page", "An older conversation"]
        for (i, title) in titles.enumerated() {
            let id = String(format: "%08d-0000-4000-8000-000000000000", i + 1)
            try object(["sessionId": "local_" + id, "cliSessionId": id,
                        "isStarred": i == 0,
                        "title": title, "cwd": cwd.path, "lastActivityAt": now.addingTimeInterval(Double(-i) * 86_400).timeIntervalSince1970 * 1000],
                       at: (i == 2 ? studioFolder : sourceFolder).appendingPathComponent("local_\(id).json"))
            if i != titles.count - 1 {
                let data = try JSONSerialization.data(withJSONObject: ["type": "user", "cwd": cwd.path,
                    "message": ["role": "user", "content": "Synthetic rendering data."]])
                try (data + Data("\n".utf8)).write(to: project.appendingPathComponent(id + ".jsonl"))
            }
        }
        try writeSampleSidebar(desktop: paths.desktop, scope: oldAccount + "/" + organization)
        let catalog = SessionCatalog(paths: paths)
        let inventory = catalog.scan(runtime: runtime, now: now)
        let sessions = SessionTransferModel(catalog: catalog, inventory: inventory, labelDefaults: nil, migrationRoot: root.appendingPathComponent("move-state"))
        let preferences = UISettings(backing: SettingsStore(defaults: renderDefaults))
        let profile = BrewProfileStore(defaults: renderDefaults)
        profile.nickname = "Your profile"
        let integrations = AgentIntegrationsModel(provider: StagedIntegrationsProvider(
            ClaudeCodeStatus(agentDetected: false, agentVersion: nil, hooksInstalled: false, needsRepair: false)))
        let router = DecafWindowRouter(); router.page = .sessions
        let view = DecafWindowView(store: AppStateStore(), settings: preferences, integrations: integrations,
            profile: profile, router: router, tabRouter: SettingsTabRouter(), commands: InertCommands(), sessions: sessions)
        for dark in [false, true] {
            Renderer.render(view, size: CGSize(width: 1060, height: 820), dark: dark,
                            to: "sessions-\(dark ? "dark" : "light").png")
            let plan = try SessionMovePlanner(catalog: catalog).prepare(sources: Set(inventory.rows.map(\.id)), destination: destination, runtime: runtime, now: now)
            Renderer.render(SessionMoveConfirmation(plan: plan, destinationLabel: sessions.label(for: plan.destination),
                cancel: {}, confirm: {}), dark: dark,
                            width: 490, to: "sessions-review-\(dark ? "dark" : "light").png")
        }
        Renderer.render(view, size: CGSize(width: 900, height: 640), dark: false, to: "sessions-compact.png")
        for store in inventory.stores where store.account != destination {
            sessions.toggleSource(store.account)
        }
        Renderer.render(view, size: CGSize(width: 900, height: 640), dark: false, to: "sessions-selected-compact.png")
        for dark in [false, true] {
            Renderer.render(view, size: CGSize(width: 1060, height: 820), dark: dark,
                to: "sessions-selected-\(dark ? "dark" : "light").png")
        }
        // The real engine acts only on this disposable synthetic tree. Neither
        // the app's quit/reopen commands nor any live account store are involved.
        let engine = SessionMoveEngine(paths: paths, stateRoot: root.appendingPathComponent("move-state"), assertDesktopStopped: {})
        let plan = try SessionMovePlanner(catalog: catalog).prepare(sources: Set(inventory.rows.map(\.id)), destination: destination, runtime: runtime, now: now)
        let moved = try engine.move(plan, now: now)
        let done = SessionTransferModel(catalog: catalog, inventory: catalog.scan(runtime: runtime), labelDefaults: nil,
            migrationRoot: root.appendingPathComponent("move-state"), receipt: moved)
        Renderer.render(SessionTransferView(model: done), size: CGSize(width: 780, height: 760), dark: false, to: "sessions-result.png")
        Renderer.render(SessionUndoConfirmation(receipt: moved, destinationLabel: done.label(for: destination), cancel: {}, confirm: {}),
            dark: false, width: 460, to: "sessions-undo.png")
        let undone = try engine.undo(moved.id)
        precondition(moved.movedCount == 3 && undone.undoneCount == 3)

    } catch { fatalError("Session rendering failed: \(error)") }
}

/// A small synthetic Chromium Local Storage WAL exercises the same metadata
/// reader as the app. It lives only in the renderer's disposable temp folder.
private func writeSampleSidebar(desktop: URL, scope: String) throws {
    let root = desktop.appendingPathComponent("Local Storage/leveldb")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    func fixed(_ n: UInt64, _ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: n >> (8 * $0)) }
    }
    func sized(_ bytes: [UInt8]) -> [UInt8] {
        var n = bytes.count, prefix: [UInt8] = []
        while n >= 128 { prefix.append(UInt8(n & 127) | 128); n >>= 7 }
        return prefix + [UInt8(n)] + bytes
    }
    func record(_ bytes: [UInt8]) -> Data {
        precondition(bytes.count < 32_761)
        var crc = UInt32.max
        for byte in [UInt8(1)] + bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0x82f63b78 : 0) }
        }
        crc = ~crc
        let masked = ((crc >> 15) | (crc << 17)) &+ 0xa282ead8
        return Data(fixed(UInt64(masked), 4) + fixed(UInt64(bytes.count), 2) + [1] + bytes)
    }
    let assignments = Dictionary(uniqueKeysWithValues: (1...3).map { index in
        ("code:local_" + String(format: "%08d-0000-4000-8000-000000000000", index), index == 2 ? "cg-product" : "cg-design")
    })
    let json = try JSONSerialization.data(withJSONObject: ["value": [scope: [
        "groups": [["id": "cg-design", "name": "Design"], ["id": "cg-product", "name": "Product"]],
        "assignments": assignments
    ]]])
    let key = Array("_https://claude.ai\0".utf8) + [1] + Array("LSS-persisted.dframe-group-scopes".utf8)
    try Data("MANIFEST-000001\n".utf8).write(to: root.appendingPathComponent("CURRENT"))
    try record([2, 3]).write(to: root.appendingPathComponent("MANIFEST-000001"))
    try record(fixed(1, 8) + fixed(1, 4) + [1] + sized(key) + sized([1] + Array(json)))
        .write(to: root.appendingPathComponent("000003.log"))
}
