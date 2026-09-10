// Recording harness: unchanged product views + real CompositionRoot / agent process.
// Decaf persistence is isolated. Codex watches only the newly created demo rollout;
// the displayed usage history is explicitly synthetic.
import AppKit
import SwiftUI
import Combine
import DecafCore
import DecafComposition
import AgentDetection
import HookWire
import UsageMetering

@main
struct LiveDemoApp: App {
    @NSApplicationDelegateAdaptor(DemoDelegate.self) private var delegate
    private var env: DemoEnvironment { .shared }
    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: env.store, commands: env.root, settings: env.settings,
                toggleGate: env.gate, tabRouter: env.tabRouter, customHold: env.customHold,
                usageStatistics: env.usage)
        } label: { DemoMenuLabel(store: env.store) }
        .menuBarExtraStyle(.menu)
        Settings { Text("Isolated recording harness · no integrations are installed.").padding(30) }
    }
}
struct DemoMenuLabel: View {
    @ObservedObject var store: AppStateStore
    var body: some View { Image(nsImage: IconRenderer.shared.image(for: store.snapshot)).help("Decaf Demo") }
}
final class DemoDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { DemoEnvironment.shared.start() }
    }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { DemoEnvironment.shared.stop() }
    }
}

@MainActor
final class DemoEnvironment: ObservableObject {
    static let shared = DemoEnvironment()
    let directory: URL
    let defaults: UserDefaults
    let suite: String
    let root: CompositionRoot
    let store: AppStateStore
    let settings: UISettings
    let gate: ManualToggleGate
    let tabRouter = SettingsTabRouter()
    let customHold: CustomHoldPresenter
    let usage: UsageStatisticsPresenter
    let profile: BrewProfileStore
    @Published var terminal = "$ claude -p \"Run sleep 6, then say: Ready for a break.\"\n"
    var agentName: String { ProcessInfo.processInfo.environment["DECAF_DEMO_CODEX_SESSION"] == nil ? "Claude Code" : "Codex" }
    @Published var running = false
    private var subscriptions: Set<AnyCancellable> = []
    private var controller: NSWindowController?
    private var process: Process?
    private var logBuffer = ""

    private init() {
        let base = ProcessInfo.processInfo.environment["DECAF_DEMO_DIRECTORY"] ?? "/tmp/decaf-live-\(UUID().uuidString)"
        directory = URL(fileURLWithPath: base)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let claude = directory.appendingPathComponent("claude/projects")
        let codex = directory.appendingPathComponent("codex/sessions")
        for path in [claude, codex] { try! FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        suite = "io.github.alany1an.decaf.demo-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        let backing = SettingsStore(defaults: defaults)
        backing.hasEverDetectedAgent = true
        backing.hasCompletedOnboarding = true
        settings = UISettings(backing: backing)
        var roots: [FSEventsWatcher.Root] = [
            .init(agent: .claudeCode, path: claude.deletingLastPathComponent().path, activityPrefix: claude.path + "/"),
            .init(agent: .codex, path: codex.deletingLastPathComponent().path, activityPrefix: codex.path + "/")
        ]
        var probe: (any CodexLogOwnerProbing)?
        if let path = ProcessInfo.processInfo.environment["DECAF_DEMO_CODEX_LOG"] {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            roots = [.init(agent: .codex, path: url.deletingLastPathComponent().path, activityPrefix: url.path)]
            probe = DemoCodexProbe(url: url)
        }
        let watcher = FSEventsWatcher(roots: roots)
        root = CompositionRoot(settings: backing, socketPath: directory.appendingPathComponent("agent.sock").path,
            watcher: watcher, codexOwnerProbe: probe, sessionsStore: SessionsStore(fileURL: directory.appendingPathComponent("sessions.json")))
        store = AppStateStore()
        profile = BrewProfileStore(defaults: defaults)
        profile.nickname = "Demo"
        usage = UsageStatisticsPresenter(store: store, profile: profile)
        gate = ManualToggleGate(store: store, commands: root)
        customHold = CustomHoldPresenter(commands: root)
        let examples = Self.exampleUsage()
        root.$snapshot.sink { [weak self] value in
            guard let self else { return }
            var displayed = value
            displayed.usage = examples
            self.store.update(displayed)
            let state = "\(Date().timeIntervalSince1970) \(MenuTextFormatter.statusLine(for: value)) wantsHold=\(value.wantsHold)\n"
            if let data = state.data(using: .utf8) {
                let path = self.directory.appendingPathComponent("state-trace.txt")
                if !FileManager.default.fileExists(atPath: path.path) { try? data.write(to: path) }
                else if let handle = try? FileHandle(forWritingTo: path) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data); try? handle.close() }
            }
        }.store(in: &subscriptions)
    }
    func start() {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .aqua)
        UserDefaults.standard.set(directory.path, forKey: "NSNavLastRootDirectory")
        terminal = "$ " + (agentName == "Codex" ? "codex exec resume" : "claude -p") + " \"Run sleep 6, then say: Ready for a break.\"\n"
        _ = root.start()
        if agentName == "Claude Code" { root.setHooksInstalled(true, for: .claudeCode) }
        let hosting = NSHostingController(rootView: DemoStage(env: self))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Decaf · live demonstration"
        window.styleMask = [.titled, .closable, .resizable]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setFrame(NSScreen.main!.visibleFrame, display: true)
        controller = NSWindowController(window: window)
        NSApp.activate(ignoringOtherApps: true)
        controller?.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        try? "\(ProcessInfo.processInfo.processIdentifier)".write(to: directory.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
    }
    func runAgent() {
        guard !running else { return }
        terminal = "$ claude -p \"Run sleep 6, then say: Ready for a break.\"\n\nStarting Claude Code…\n"
        if agentName == "Codex" { terminal = "$ codex exec resume \"Run sleep 6, then say: Ready for a break.\"\n\nStarting Codex…\n" }
        running = true
        let bridge = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/decaf-bridge").path
        let command = "'" + bridge.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let hooks = Dictionary(uniqueKeysWithValues: ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"].map {
            ($0, [["hooks": [["type": "command", "command": command]]]])
        })
        let config = directory.appendingPathComponent("claude-settings.json")
        try! JSONSerialization.data(withJSONObject: ["hooks": hooks]).write(to: config)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DECAF_DEMO_CLAUDE"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path)
        task.currentDirectoryURL = directory
        task.arguments = ["-p", "Use Bash to run exactly sleep 6, then reply with exactly: Ready for a break.",
            "--system-prompt", "Follow the user's one small demonstration task. Do not inspect files or run other commands.",
            "--setting-sources", "", "--settings", config.path,
            "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--disable-slash-commands", "--no-chrome",
            "--no-session-persistence", "--tools", "Bash", "--allowedTools", "Bash(sleep 6)", "--permission-mode", "dontAsk",
            "--effort", "low", "--output-format", "stream-json", "--verbose"]
        if let session = ProcessInfo.processInfo.environment["DECAF_DEMO_CODEX_SESSION"] {
            task.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DECAF_DEMO_CODEX"] ?? "/Applications/ChatGPT.app/Contents/Resources/codex")
            task.arguments = ["exec", "--sandbox", "read-only", "resume", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check", "--json", session,
                "For a Decaf product demonstration, run exactly sleep 6 using the shell tool, then reply exactly: Ready for a break. Do not read or modify any files."]
        }
        var environment = ProcessInfo.processInfo.environment
        environment["DECAF_BRIDGE_SOCKET"] = directory.appendingPathComponent("agent.sock").path
        environment["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
        task.environment = environment
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.receive(text) }
        }
        task.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.running = false
                self.terminal += "\nProcess exited: \(process.terminationStatus)\n"
                try? self.terminal.write(to: self.directory.appendingPathComponent("agent-output.txt"), atomically: true, encoding: .utf8)
            }
        }
        process = task
        do { try task.run() }
        catch { running = false; terminal += "Unable to start \(agentName).\n" }
    }
    private func receive(_ text: String) {
        logBuffer += text
        while let end = logBuffer.firstIndex(of: "\n") {
            let line = String(logBuffer[..<end]); logBuffer.removeSubrange(...end)
            guard let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let type = object["type"] as? String, let item = object["item"] as? [String: Any] {
                if type == "item.started", item["type"] as? String == "command_execution", let command = item["command"] as? String { terminal += "$ " + command + "\n" }
                if type == "item.completed", item["type"] as? String == "agent_message", let text = item["text"] as? String { terminal += text + "\n" }
            }
            if object["type"] as? String == "assistant",
               let message = object["message"] as? [String: Any], let blocks = message["content"] as? [[String: Any]] {
                for block in blocks {
                    if let text = block["text"] as? String { terminal += text + "\n" }
                    if block["type"] as? String == "tool_use", block["name"] as? String == "Bash",
                       let input = block["input"] as? [String: Any], let command = input["command"] as? String { terminal += "$ " + command + "\n" }
                }
            }
            if object["type"] as? String == "result", object["is_error"] as? Bool == true { terminal += "Claude reported an error.\n" }
        }
    }
    func stop() {
        process?.terminate()
        root.stop()
        defaults.removePersistentDomain(forName: suite)
    }
    private static func exampleUsage() -> UsageOverview {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        let dates = (0..<42).reversed().map { Calendar.current.date(byAdding: .day, value: -$0, to: Date())! }
        func snapshot(codex: Bool) -> UsageSnapshot {
            let history = dates.enumerated().map { index, date in
                let total = index % 7 == 0 ? 0 : (index * (codex ? 89_000 : 173_000)) % (codex ? 600_000 : 1_200_000) + 60_000
                return DailyUsage(day: formatter.string(from: date), tokens: TokenTotals(input: total * 3 / 10, output: total / 10, cacheRead: total * 6 / 10))
            }
            return UsageSnapshot(today: history.last!.tokens, todayCostUSD: nil, todayHasUnpricedModels: true,
                activeBlock: nil, sevenDayTokens: TokenTotals(), sessions: [], dailyHistory: Array(history.suffix(7)), recordedHistory: history,
                sourceStatus: UsageSourceStatus(hasCompletedScan: true, filesRead: 24, lastReadAt: Date()))
        }
        return UsageOverview(usage: snapshot(codex: false), quotaFiveHour: nil, quotaSevenDay: nil,
            quotaProvenance: .estimated, codexUsage: snapshot(codex: true))
    }
}

/// Restrict the production FD probe to this demo's newly created rollout.
/// Other writable-log paths may be enumerated, but their records never reach the detector.
private struct DemoCodexProbe: CodexLogOwnerProbing {
    let url: URL
    func openLogs() -> [CodexLogOwner] {
        CodexLogOwnerProbe(activityRoots: [url.deletingLastPathComponent()]).openLogs()
            .filter { $0.url == url.resolvingSymlinksInPath().standardizedFileURL }
    }
}

struct DemoStage: View {
    @ObservedObject var env: DemoEnvironment
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack { Text("decaf.").font(.custom("Georgia-Bold", size: 34)); Spacer(); Text("LIVE AGENT + NATIVE UI · SAMPLE USAGE HISTORY").font(.system(size: 13, design: .monospaced)) }
            Spacer()
            VStack(alignment: .leading, spacing: 20) {
                Text("Automatic keep-awake.\nClaude Code + Codex usage.").font(.custom("Georgia", size: 35))
                Text(env.agentName + " · live process").font(.system(size: 13, weight: .semibold))
                Text(env.terminal).font(.system(size: 14, design: .monospaced)).textSelection(.enabled)
                    .frame(width: 540, height: 260, alignment: .topLeading).padding(22).background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                HStack(spacing: 16) {
                    Button("Run agent") { env.runAgent() }.disabled(env.running)
                    Button("Open usage") { env.usage.present() }
                }.controlSize(.large)
                Text("Live agent detection. Monthly history is example data.\nNo personal logs or profile preferences are loaded.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Text("Development preview · github.com/AlanY1an/decaf").font(.system(size: 12, design: .monospaced))
        }.padding(55).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .foregroundStyle(Color(red: 0.24, green: 0.235, blue: 0.20))
            .background(Color(red: 0.945, green: 0.932, blue: 0.891))
    }
}
