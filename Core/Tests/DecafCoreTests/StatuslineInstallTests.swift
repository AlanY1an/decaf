// StatuslineInstallTests — plan 09 M3b: the IO side of the statusline bridge
// install. Runs against a temp home directory with the real DefaultFileSystem
// (the pure merge logic has its own suite; this covers the file choreography:
// binary copy, sidecar, backup, restore). Never touches the real ~/.claude.

import Foundation
import Testing
@testable import DecafCore

private struct StatuslineHarness {
    let home: URL
    let paths: IntegrationPaths
    let bundledDirectory: URL

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("decaf-statusline-install-\(UUID().uuidString)", isDirectory: true)
        bundledDirectory = home.appendingPathComponent("Bundle/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: bundledDirectory, withIntermediateDirectories: true)
        try Data("bundled-bridge".utf8)
            .write(to: bundledDirectory.appendingPathComponent("decaf-bridge"))
        try Data("bundled-statusline".utf8)
            .write(to: bundledDirectory.appendingPathComponent("decaf-statusline"))
        paths = IntegrationPaths(homeDirectory: home.path)
    }

    func makeIntegration() -> ClaudeCodeIntegration {
        ClaudeCodeIntegration(
            fileSystem: DefaultFileSystem(),
            processRunner: SystemProcessRunner(),
            configuration: .init(
                homeDirectory: home.path,
                bundledBridgePath: bundledDirectory.appendingPathComponent("decaf-bridge").path,
                bridgeVersion: "1.0.0"
            )
        )
    }

    func writeSettings(_ object: [String: Any]) throws {
        let directory = URL(fileURLWithPath: paths.claudeConfigDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: URL(fileURLWithPath: paths.claudeSettingsFile))
    }

    func settingsObject() throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: paths.claudeSettingsFile))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: home)
    }
}

@Suite("Statusline install IO")
struct StatuslineInstallTests {

    @Test func installCopiesBinaryWritesSidecarAndSwapsTheSlot() throws {
        let harness = try StatuslineHarness()
        defer { harness.cleanUp() }
        let integration = harness.makeIntegration()

        try harness.writeSettings(["statusLine": ["type": "command", "command": "~/hud.sh"]])
        try integration.installStatusline()

        #expect(FileManager.default.fileExists(atPath: harness.paths.statuslineBinary))
        #expect(integration.statuslineInstalled())

        let settings = try harness.settingsObject()
        let command = try #require((settings["statusLine"] as? [String: Any])?["command"] as? String)
        #expect(command.contains("decaf-statusline"))

        let sidecar = try Data(contentsOf: URL(fileURLWithPath: harness.paths.statuslineChainFile))
        let payload = try #require(try JSONSerialization.jsonObject(with: sidecar) as? [String: Any])
        let previous = try #require(payload["previous"] as? [String: Any])
        #expect(previous["command"] as? String == "~/hud.sh")
    }

    @Test func reinstallKeepsTheCapturedChain() throws {
        let harness = try StatuslineHarness()
        defer { harness.cleanUp() }
        let integration = harness.makeIntegration()

        try harness.writeSettings(["statusLine": ["type": "command", "command": "~/hud.sh"]])
        try integration.installStatusline()
        try integration.installStatusline()   // second run captures nothing

        let sidecar = try Data(contentsOf: URL(fileURLWithPath: harness.paths.statuslineChainFile))
        let payload = try #require(try JSONSerialization.jsonObject(with: sidecar) as? [String: Any])
        #expect((payload["previous"] as? [String: Any])?["command"] as? String == "~/hud.sh")
    }

    @Test func uninstallRestoresTheOriginalAndRemovesOurFiles() throws {
        let harness = try StatuslineHarness()
        defer { harness.cleanUp() }
        let integration = harness.makeIntegration()

        let original: [String: Any] = ["statusLine": ["type": "command", "command": "~/hud.sh"], "model": "opus"]
        try harness.writeSettings(original)
        try integration.installStatusline()
        try integration.uninstallStatusline()

        let settings = try harness.settingsObject()
        #expect(ClaudeSettingsEditor.semanticallyEqual(settings, original))
        #expect(!FileManager.default.fileExists(atPath: harness.paths.statuslineChainFile))
        #expect(!FileManager.default.fileExists(atPath: harness.paths.statuslineBinary))
        #expect(!integration.statuslineInstalled())
    }

    @Test func installWithNoSettingsFileCreatesOne() throws {
        let harness = try StatuslineHarness()
        defer { harness.cleanUp() }
        let integration = harness.makeIntegration()

        try integration.installStatusline()
        #expect(integration.statuslineInstalled())

        try integration.uninstallStatusline()
        let settings = try harness.settingsObject()
        #expect(settings["statusLine"] == nil)
    }

    @Test func uninstallNeverTouchesAForeignStatusline() throws {
        let harness = try StatuslineHarness()
        defer { harness.cleanUp() }
        let integration = harness.makeIntegration()

        let foreign: [String: Any] = ["statusLine": ["type": "command", "command": "~/other.sh"]]
        try harness.writeSettings(foreign)
        try integration.uninstallStatusline()
        let settings = try harness.settingsObject()
        #expect(ClaudeSettingsEditor.semanticallyEqual(settings, foreign))
    }
}
