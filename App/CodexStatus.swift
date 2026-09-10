import Foundation
import AgentDetection

enum CodexStatus: Equatable, Sendable {
    case notFound, installed, localSessions

    var agentDetected: Bool { self != .notFound }
    var title: String {
        switch self {
        case .notFound: return "No local sessions found yet"
        case .installed: return "Installed · waiting for a local session"
        case .localSessions: return "Local session folder found"
        }
    }

    /// Uses the same data root as the watcher. A config/skills-only directory
    /// is not evidence of sessions, and no shell or agent is launched.
    static func probe(home: String = NSHomeDirectory(),
                      codexHome: String? = ProcessInfo.processInfo.environment["CODEX_HOME"],
                      searchPath: String = (ProcessInfo.processInfo.environment["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin",
                      applications: [String] = ["/Applications/Codex.app"]) -> CodexStatus {
        let root = FSEventsWatcher.Root.codex(home: home, codexHome: codexHome).path
        let fm = FileManager.default
        func directoryExists(_ path: String) -> Bool {
            var directory: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
        }
        if ["sessions", "archived_sessions"].contains(where: {
            directoryExists((root as NSString).appendingPathComponent($0))
        }) { return .localSessions }
        let paths = searchPath.split(separator: ":").map(String.init)
            + [home + "/.local/bin", home + "/.npm-global/bin"]
        if paths.contains(where: { fm.isExecutableFile(atPath: ($0 as NSString).appendingPathComponent("codex")) })
            || (applications + [home + "/Applications/Codex.app"]).contains(where: directoryExists) {
            return .installed
        }
        return .notFound
    }
}

struct OnboardingAgentsSummary {
    let claudeDetected: Bool
    let codexDetected: Bool
    let isProbing: Bool

    var message: String {
        if isProbing { return "Looking for your coding tools…" }
        if claudeDetected && codexDetected { return "Both tools, one little daily receipt." }
        if codexDetected { return "Codex is ready. Local usage appears automatically after a session." }
        if claudeDetected { return "Claude Code is ready. Add Codex any time — Decaf follows both." }
        return "No tools found yet. Run Claude Code or Codex once and Decaf will pick up local sessions. Manual keep-awake works right away."
    }
}
