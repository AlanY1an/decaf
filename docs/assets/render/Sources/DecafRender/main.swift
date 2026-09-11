// DecafRender — offscreen renderer for Decaf's real SwiftUI views.
//
// Needs no permission of any kind: NSHostingView draws into an NSBitmapImageRep
// via cacheDisplay(in:to:). Nothing is ever ordered on screen, no window server
// capture happens, and no Apple events are sent.
//
// Every view rendered here is the SHIPPING view, compiled from a fresh copy of
// the repo's App/ directory (build.sh re-copies on every run). Only the *inputs* are staged (a throwaway
// UserDefaults suite, a static integrations provider, a synthetic home path);
// no view is reimplemented or approximated.

import AppKit
import SwiftUI
import DecafCore
import UsageMetering

// MARK: - Output

let arguments = CommandLine.arguments.dropFirst()
/// `--measure` prints the sizing numbers `SettingsView` is built on and writes
/// no images. It is how the window height in SettingsView.swift is derived, and
/// re-running it is how the next person checks that number instead of trusting
/// the comment next to it.
let measureOnly = arguments.contains("--measure")
let outputDirectory = arguments.first(where: { !$0.hasPrefix("--") })
    ?? FileManager.default.currentDirectoryPath

// MARK: - Offscreen renderer

enum Renderer {
    /// Renders `view` at `size` points, `scale`x, into a PNG.
    ///
    /// The view is parented in an off-screen `NSWindow` because SwiftUI needs a
    /// window to resolve `Form`/`TabView` platform styling and the material
    /// backgrounds; the window is never ordered front, never made key, and
    /// never displayed.
    @MainActor
    static func render<V: View>(
        _ view: V,
        size: CGSize? = nil,
        scale: CGFloat = 2,
        dark: Bool,
        chrome: Bool = false,
        title: String = "",
        width: CGFloat = 620,
        to filename: String
    ) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        NSApp.appearance = appearance

        // Natural height when the caller does not pin one: what the page itself
        // asks for, so nothing is silently cut off at the bottom of the frame.
        let resolved: CGSize
        if let size {
            resolved = size
        } else {
            let probe = NSHostingView(rootView: view)
            probe.appearance = appearance
            probe.frame = CGRect(x: 0, y: 0, width: width, height: 2000)
            let fitting = probe.fittingSize
            // +8pt of slack: fittingSize rounds a grouped Form's last card a
            // point or two short and the bottom corner radius gets shaved.
            resolved = CGSize(width: width, height: ceil(max(fitting.height, 1)) + 8)
        }

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: resolved),
            styleMask: chrome ? [.titled, .closable, .miniaturizable] : [.borderless],
            backing: .buffered,
            defer: false
        )
        // Appearance on the window BEFORE the hosting view is installed: an
        // NSVisualEffectView (which is what a TabView's tab strip is) resolves
        // its material once, from the effective appearance it is first added
        // under. Setting it afterwards leaves the strip painted for the wrong
        // side and it renders as a blank band.
        window.appearance = appearance
        window.title = title
        window.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: view)
        hosting.appearance = appearance
        hosting.frame = CGRect(origin: .zero, size: resolved)
        window.contentView = hosting

        makeKey(window)
        settle(0.9)

        // Always the window's frame view, never the hosting view alone.
        //
        // Two reasons, and the second one cost a wrong image before it was
        // caught: with `chrome` the frame view is what AppKit draws the title
        // bar and traffic lights into, so the chrome in the capture is real
        // chrome rather than an imitation. WITHOUT chrome it is what paints
        // `windowBackgroundColor` under the content — and a view like
        // InstallConsentSheet, which has no background of its own because a real
        // sheet gets one from its window, otherwise captures as nothing but ink
        // on transparency. In dark mode that ink is white, and the first attempt
        // (flattening onto a colour computed here) resolved the light
        // windowBackgroundColor and produced a white-on-white blank.
        // Letting the window paint its own background cannot get this wrong.
        write(hosting.superview ?? hosting, scale: scale, to: filename)
    }

    /// Renders an already-built window (OnboardingWindowController,
    /// CustomHoldWindowController) without showing it.
    @MainActor
    static func renderWindow(
        _ window: NSWindow,
        scale: CGFloat = 2,
        dark: Bool,
        chrome: Bool = true,
        followsAppAppearance: Bool = false,
        to filename: String
    ) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        NSApp.appearance = appearance
        window.appearance = followsAppAppearance ? nil : appearance

        makeKey(window)
        settle(0.9)

        guard let content = window.contentView else {
            FileHandle.standardError.write(Data("no content view for \(filename)\n".utf8))
            return
        }
        let target: NSView = chrome ? (content.superview ?? content) : content
        write(target, scale: scale, to: filename)
    }

    /// AppKit draws switches, pickers and buttons in their unemphasised grey
    /// when the window is not key — the real Settings window a user is looking
    /// at IS key, so an un-keyed capture shows the wrong colour for every
    /// control. `makeKeyWindow()` sets that state without ordering the window
    /// on screen: nothing is displayed, no space is switched, no other app is
    /// deactivated.
    @MainActor
    static func makeKey(_ window: NSWindow) {
        window.makeKey()
    }

    /// Delivers a click straight into the window's own event queue.
    ///
    /// This is `NSWindow.sendEvent` on a window this process owns — not a
    /// CGEvent post and not an Apple event, so it needs no Accessibility or
    /// Automation permission and touches nothing outside this process. It is
    /// how the onboarding flow is advanced to steps 2 and 3, whose `step` state
    /// is private to OnboardingWindow.swift and cannot be set from outside.
    ///
    /// `location` is in window coordinates (origin bottom-left).
    @MainActor
    static func click(_ window: NSWindow, at location: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            window.sendEvent(event)
        }
        settle(0.3)
    }

    /// Lets SwiftUI finish its first layout/render pass and any onAppear work.
    @MainActor
    static func settle(_ seconds: TimeInterval = 0.45) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    @MainActor
    private static func write(
        _ view: NSView,
        scale: CGFloat,
        to filename: String
    ) {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        let pixelsWide = Int((bounds.width * scale).rounded())
        let pixelsHigh = Int((bounds.height * scale).rounded())

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            FileHandle.standardError.write(Data("rep alloc failed for \(filename)\n".utf8))
            return
        }
        // Points, not pixels — this is what makes cacheDisplay draw at `scale`.
        rep.size = bounds.size

        view.cacheDisplay(in: bounds, to: rep)

        if ProcessInfo.processInfo.environment["DECAF_RENDER_PROBE"] != nil {
            for y in [4, 20, 40, 60] where y < pixelsHigh {
                let c = rep.colorAt(x: pixelsWide / 2, y: y)
                print("      probe y=\(y): \(c.map { "r\($0.redComponent) g\($0.greenComponent) b\($0.blueComponent) a\($0.alphaComponent)" } ?? "nil")")
            }
        }

        guard let data = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("png encode failed for \(filename)\n".utf8))
            return
        }
        let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent(filename)
        do {
            try data.write(to: url)
            print("  \(filename)  \(pixelsWide)x\(pixelsHigh) px  (\(Int(bounds.width))x\(Int(bounds.height)) pt @\(Int(scale))x)")
        } catch {
            FileHandle.standardError.write(Data("write failed \(filename): \(error)\n".utf8))
        }
    }
}

// MARK: - Measurement

/// The numbers `SettingsView.windowHeight` is derived from.
///
/// Everything here is measured, never estimated. A grouped `Form` resolves its
/// platform metrics from the window it is hosted in, so each page is measured
/// inside a real offscreen window — the same one the renders use — rather than
/// from a bare `NSHostingView`, which reports a different figure.
enum Measure {
    /// What a view asks for at `width` when nothing pins its height.
    @MainActor
    static func naturalHeight<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: width, height: 2000),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: 2000)
        window.contentView = hosting
        window.makeKey()
        Renderer.settle(0.6)
        hosting.layoutSubtreeIfNeeded()
        return ceil(hosting.fittingSize.height)
    }

    /// The assembled settings window with `tab` selected and nothing pinning
    /// its height: tab strip, TabView insets and the page, all at once.
    ///
    /// This, and not the page on its own, is the number the window has to
    /// clear. A page inside a TabView is laid out narrower than the window, so
    /// measuring `AgentsSettingsTab` alone at 620pt reports a page that wraps
    /// less than the real one and comes out short. That is exactly how the
    /// window ended up 25pt too small.
    @MainActor
    static func tabHeight(
        _ tab: SettingsTab,
        settings: UISettings,
        status: ClaudeCodeStatus,
        width: CGFloat
    ) -> CGFloat {
        let router = SettingsTabRouter()
        router.selectedTab = tab
        return naturalHeight(
            SettingsTabs(
                settings: settings,
                integrations: AgentIntegrationsModel(provider: StagedIntegrationsProvider(status)),
                tabRouter: router,
                profile: BrewProfileStore(defaults: renderDefaults), showProfile: {}
            ),
            width: width
        )
    }
}

// MARK: - Staged inputs

/// A UserDefaults suite that exists only for this process, so every render shows
/// Decaf's factory defaults and the author's own preferences are never read or
/// written.
let renderSuiteName = "io.github.alany1an.decaf.render-\(UUID().uuidString)"
let renderDefaults = UserDefaults(suiteName: renderSuiteName)!

/// A home directory that does not exist. `plannedChanges()` only calls
/// `fileExists`, so this is a read-only, side-effect-free way to get the REAL
/// planned-change list out of Core without reading the author's ~/.claude — and
/// it keeps a real username out of a published screenshot.
let syntheticHome = "/Users/you"

let realIntegration = ClaudeCodeIntegration(
    fileSystem: DefaultFileSystem(),
    processRunner: SystemProcessRunner(),
    configuration: .init(
        homeDirectory: syntheticHome,
        bundledBridgePath: "/Applications/Decaf.app/Contents/Helpers/decaf-bridge",
        bridgeVersion: "0.1.0"
    )
)

/// Feeds the real `AgentIntegrationsModel` a chosen status without probing the
/// machine. `plannedChanges()` still comes from Core's real implementation.
@MainActor
final class StagedIntegrationsProvider: AgentIntegrationsProviding {
    var status: ClaudeCodeStatus
    var codex: CodexStatus
    init(_ status: ClaudeCodeStatus, codex: CodexStatus = .localSessions) {
        self.status = status
        self.codex = codex
    }
    func probeCodex() async -> CodexStatus { codex }

    func probeClaudeCode() async -> ClaudeCodeStatus { status }
    func plannedChanges() -> [PlannedChangeSummary] {
        realIntegration.plannedChanges().map {
            PlannedChangeSummary(
                path: $0.path,
                kind: $0.kind == PlannedChange.Kind.create ? .create : .modify,
                preview: $0.preview
            )
        }
    }
    func installClaudeCodeHooks() throws {}
    func uninstallClaudeCodeHooks() throws {}
    func installStatusline() throws {}
    func uninstallStatusline() throws {}
    func removeAllIntegrations() throws {}
}

/// A registrar that reports "off" and refuses to touch SMAppService, so the
/// onboarding step-3 render cannot register a login item on this machine.
@MainActor
final class InertRegistrar: LaunchAtLoginRegistering {
    var status: LaunchAtLoginStatus { .notRegistered }
    func register() throws {}
    func unregister() throws {}
}

/// Rendering never executes keep-awake commands.
@MainActor
final class InertCommands: AppCommands {
    func toggleManual() {}
    func startManual(_ mode: ManualMode) {}
    func holdUntil(_ deadline: Date) {}
    func stopManual() {}
    func confirmLowBatteryOverride() {}
    func setDisplayPolicy(_ policy: DisplayPolicy) {}
    func setAgentAutoKeepAwake(_ enabled: Bool) {}
    func turnOffDisplayNow() {}
}

// MARK: - Run

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)   // never a foreground app, never a Dock tile

MainActor.assumeIsolated {
    if arguments.contains("--updates") {
        for dark in [false, true] {
            Renderer.render(UpdateGuideView(), dark: dark, width: 420,
                            to: "updates-\(dark ? "dark" : "light").png")
        }
        return
    }
    if arguments.contains("--usage") || arguments.contains("--profile") || arguments.contains("--marketing") || arguments.contains("--interface") {
        let amounts = [420_000, 1_100_000, 650_000, 1_320_000, 300_000, 940_000, 1_840_000]
        func split(_ n: Int) -> TokenTotals {
            TokenTotals(input: n * 30 / 100, output: n * 7 / 100,
                        cacheCreation: n * 3 / 100, cacheRead: n * 60 / 100)
        }
        // The interface header uses today's date. Keep its synthetic history aligned.
        let sampleDateFormatter = DateFormatter()
        sampleDateFormatter.calendar = Calendar(identifier: .gregorian)
        sampleDateFormatter.locale = Locale(identifier: "en_US_POSIX")
        sampleDateFormatter.dateFormat = "yyyy-MM-dd"
        func sampleDay(_ index: Int) -> String {
            guard arguments.contains("--interface") else {
                return String(format: "2026-09-%02d", index + 2)
            }
            return sampleDateFormatter.string(from: Calendar.current.date(byAdding: .day, value: index - 6, to: Date())!)
        }
        let claudeHistory = amounts.enumerated().map { index, n in
            DailyUsage(day: sampleDay(index), tokens: split(index == 6 ? 1_200_000 : n * 65 / 100))
        }
        let codexHistory = amounts.enumerated().map { index, n in
            DailyUsage(day: sampleDay(index), tokens: split(index == 6 ? 640_000 : n - n * 65 / 100))
        }
        let augustClaude = (1...31).map { day in
            DailyUsage(day: String(format: "2026-08-%02d", day),
                       tokens: split(day % 7 == 0 ? 0 : (day * 173_000) % 1_200_000 + 80_000))
        }
        let augustCodex = (1...31).map { day in
            DailyUsage(day: String(format: "2026-08-%02d", day),
                       tokens: split(day % 7 == 0 ? 0 : (day * 89_000) % 600_000 + 60_000))
        }
        func snapshot(_ days: [DailyUsage], history: [DailyUsage] = []) -> UsageSnapshot {
            UsageSnapshot(today: days.last?.tokens ?? TokenTotals(), todayCostUSD: nil,
                          todayHasUnpricedModels: true, activeBlock: nil,
                          sevenDayTokens: TokenTotals(), sessions: [], dailyHistory: days,
                          recordedHistory: history + days,
                          sourceStatus: UsageSourceStatus(hasCompletedScan: true, filesRead: 24,
                              lastReadAt: ISO8601DateFormatter().date(from: "2026-09-08T20:35:00Z")))
        }
        let usage = UsageOverview(usage: snapshot(claudeHistory, history: augustClaude), quotaFiveHour: nil,
                                  quotaSevenDay: nil, quotaProvenance: .estimated,
                                  codexUsage: snapshot(codexHistory, history: augustCodex))
        if arguments.contains("--interface") {
            let preferences = UISettings(backing: SettingsStore(defaults: renderDefaults))
            let profile = BrewProfileStore(defaults: renderDefaults)
            profile.nickname = "Alan"
            let integrations = AgentIntegrationsModel(provider: StagedIntegrationsProvider(
                ClaudeCodeStatus(agentDetected: true, agentVersion: nil, hooksInstalled: true, needsRepair: false)))
            let router = DecafWindowRouter(), tabs = SettingsTabRouter()
            let store = AppStateStore(snapshot: AppStateSnapshot(fallbackAgents: [.claudeCode, .codex], wantsHold: true, usage: usage))
            let view = DecafWindowView(store: store, settings: preferences, integrations: integrations,
                                      profile: profile, router: router, tabRouter: tabs, commands: InertCommands())
            if arguments.contains("--window-chrome") {
                router.page = .settings
                let window = NSWindow(contentViewController: NSHostingController(rootView: view))
                window.title = "Decaf"
                window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
                DecafWindowAppearance.apply(to: window, surface: .brew)
                window.setContentSize(NSSize(width: 1060, height: 820))
                let updates = NSWindow(contentViewController: NSHostingController(rootView: UpdateGuideView()))
                updates.title = "Decaf Updates"
                updates.styleMask = [.titled, .closable]
                DecafWindowAppearance.apply(to: updates)
                let hold = CustomHoldWindowController(commit: { _ in }, didClose: {})
                hold.retarget(.duration)
                let onboarding = OnboardingWindowController(settings: preferences, integrations: integrations,
                    launchAtLogin: LaunchAtLoginChoice(isEnabled: false, registrar: InertRegistrar()), onFinished: {})
                // Reuse each window while the app appearance changes. A fresh
                // window for every image would miss stale title-bar colors.
                for (name, dark) in [("light", false), ("dark", true), ("light-again", false)] {
                    Renderer.renderWindow(window, dark: dark, followsAppAppearance: true, to: "chrome-settings-\(name).png")
                    Renderer.renderWindow(updates, dark: dark, followsAppAppearance: true, to: "chrome-updates-\(name).png")
                    Renderer.renderWindow(hold.window!, dark: dark, followsAppAppearance: true, to: "chrome-hold-\(name).png")
                    Renderer.renderWindow(onboarding.window!, dark: dark, followsAppAppearance: true, to: "chrome-onboarding-\(name).png")
                }
                renderDefaults.removePersistentDomain(forName: renderSuiteName)
                return
            }
            for dark in [false, true] {
                router.page = .home
                Renderer.render(view, size: CGSize(width: 1060, height: 820), dark: dark,
                                to: "home-\(dark ? "dark" : "light").png")
                router.page = .settings
                for (tab, name) in [(SettingsTab.general, "general"), (.agents, "agents"), (.safety, "safety"), (.profile, "profile")] {
                    tabs.selectedTab = tab
                    Renderer.render(view, size: CGSize(width: 1060, height: 820), dark: dark,
                                    to: "settings-\(name)-\(dark ? "dark" : "light").png")
                }
            }
            router.page = .home
            Renderer.render(view, size: CGSize(width: 900, height: 640), dark: false, to: "home-compact.png")
            store.update(AppStateSnapshot(safetyPause: .lowBattery(percent: 12, threshold: 20), wantsHold: true))
            Renderer.render(view, size: CGSize(width: 1060, height: 820), dark: false, to: "home-loading-safety.png")
            renderDefaults.removePersistentDomain(forName: renderSuiteName)
            return
        }
        if arguments.contains("--marketing") {
            MarketingAssets.render(usage: usage)
            renderDefaults.removePersistentDomain(forName: renderSuiteName)
            exit(0)
        }
        if arguments.contains("--profile") {
            let now = ISO8601DateFormatter().date(from: "2026-09-08T20:35:00Z")!
            let profile = BrewProfileStore(defaults: renderDefaults)
            profile.nickname = "Alan"
            let router = UsagePageRouter(page: .profile)
            let model = UsageProfileModel(overview: usage, now: now)
            for dark in [false, true] {
                let suffix = dark ? "dark" : "light"
                Renderer.render(UsageDashboardContent(overview: usage, profile: profile, router: router, now: now),
                                size: CGSize(width: 600, height: 860), dark: dark, chrome: true,
                                title: "Decaf", to: "profile-\(suffix).png")
                for showsTotals in [false, true] {
                    profile.showsTokenTotals = showsTotals
                    let card = BrewProfileShareModel(profile: profile.value, usage: model)
                    if let data = BrewProfileShareRenderer.pngData(for: card, dark: dark) {
                        try! data.write(to: URL(fileURLWithPath: outputDirectory)
                            .appendingPathComponent("profile-card-\(showsTotals ? "tokens" : "activity")-\(suffix).png"))
                    }
                }
            }
            profile.nickname = String(repeating: "长名字", count: 16)
            profile.avatar = .moon
            Renderer.render(UsageDashboardContent(overview: usage, profile: profile, router: router, now: now),
                            size: CGSize(width: 500, height: 860), dark: false, to: "profile-narrow-long-name.png")
            if let data = BrewProfileShareRenderer.pngData(for: BrewProfileShareModel(profile: profile.value, usage: model), dark: false) {
                try! data.write(to: URL(fileURLWithPath: outputDirectory).appendingPathComponent("profile-card-long-name.png"))
            }
            profile.nickname = ""
            profile.avatar = .cup
            let empty = UsageOverview(usage: snapshot([]), quotaFiveHour: nil, quotaSevenDay: nil, quotaProvenance: .estimated)
            for (label, overview) in [("empty", Optional(empty)), ("loading", nil)] {
                Renderer.render(UsageDashboardContent(overview: overview, profile: profile, router: router, now: now),
                                size: CGSize(width: 600, height: 860), dark: false, to: "profile-\(label).png")
            }
            var partial = usage
            partial.usage.historyIssue = "Some local records need review."
            Renderer.render(UsageProfileContent(overview: partial, profile: profile, now: now),
                            size: CGSize(width: 600, height: 820), dark: false, to: "profile-partial.png")
            let partialCard = BrewProfileShareModel(profile: profile.value, usage: UsageProfileModel(overview: partial, now: now))
            if let data = BrewProfileShareRenderer.pngData(for: partialCard, dark: false) {
                try! data.write(to: URL(fileURLWithPath: outputDirectory).appendingPathComponent("profile-card-partial.png"))
            }
            profile.nickname = "Alan"
            Renderer.render(ProfileSettingsTab(profile: profile, showProfile: {}),
                            size: CGSize(width: 600, height: 630), dark: false, to: "profile-settings.png")
            Renderer.render(BrewProfileShareSheet(profile: profile, usage: model),
                            size: CGSize(width: 548, height: 710), dark: false, to: "profile-share-preview.png")
            let augustModel = UsageProfileModel(overview: usage, now: now, monthID: "2026-08-01")
            profile.showsTokenTotals = false
            for dark in [false, true] {
                let suffix = dark ? "dark" : "light"
                Renderer.render(UsageProfileContent(overview: usage, profile: profile, now: now, monthID: "2026-08-01"),
                                size: CGSize(width: 600, height: 860), dark: dark, chrome: true,
                                title: "Decaf", to: "profile-previous-month-\(suffix).png")
                let card = BrewProfileShareModel(profile: profile.value, usage: augustModel)
                if let data = BrewProfileShareRenderer.pngData(for: card, dark: dark) {
                    try! data.write(to: URL(fileURLWithPath: outputDirectory)
                        .appendingPathComponent("profile-previous-month-card-\(suffix).png"))
                }
            }
            Renderer.render(UsageProfileContent(overview: usage, profile: profile, now: now, monthID: "2026-08-01"),
                            size: CGSize(width: 500, height: 860), dark: false, to: "profile-previous-month-narrow.png")
            Renderer.render(BrewProfileShareSheet(profile: profile, usage: augustModel, appearance: .dark),
                            size: CGSize(width: 548, height: 710), dark: false, to: "profile-share-dark-on-light.png")
            Renderer.render(BrewProfileShareSheet(profile: profile, usage: augustModel, appearance: .light),
                            size: CGSize(width: 548, height: 710), dark: true, to: "profile-share-light-on-dark.png")
            renderDefaults.removePersistentDomain(forName: renderSuiteName)
            exit(0)
        }
        var noLogs = usage
        noLogs.usage = UsageSnapshot(today: TokenTotals(), todayCostUSD: nil,
            todayHasUnpricedModels: false, activeBlock: nil, sevenDayTokens: TokenTotals(), sessions: [],
            sourceStatus: UsageSourceStatus(hasCompletedScan: true))
        noLogs.codexUsage = noLogs.usage
        Renderer.render(UsageStatisticsContent(overview: noLogs), size: CGSize(width: 500, height: 700),
                        dark: false, to: "usage-no-logs.png")
        Renderer.render(UsageStatisticsContent(overview: nil), size: CGSize(width: 500, height: 700),
                        dark: false, to: "usage-importing.png")
        for dark in [false, true] {
            Renderer.render(UsageDataSourcesView(status: UsageDataStatusModel(overview: usage)),
                            dark: dark, width: 360,
                            to: "usage-sources-\(dark ? "dark" : "light").png")
            Renderer.render(UsageStatisticsContent(overview: usage), size: CGSize(width: 600, height: 700),
                            dark: dark, to: "usage-\(dark ? "dark" : "light").png")
            let model = UsageStatisticsModel(overview: usage)
            guard let day = model.selectedDay(nil) else { fatalError("Missing example day") }
            let card = UsageShareCardModel(day: day, agent: .all,
                dateLabel: model.dateLabel(day.id, format: "MMM d, yyyy"))
            guard let data = UsageShareCardRenderer.pngData(for: card, dark: dark) else {
                fatalError("Share card rendering failed")
            }
            let name = "usage-card-\(dark ? "dark" : "light").png"
            try! data.write(to: URL(fileURLWithPath: outputDirectory).appendingPathComponent(name))
            print("  \(name)  actual clipboard PNG renderer")
        }
        for dark in [false, true] {
            Renderer.render(UsageStatisticsContent(overview: usage, period: .monthly, monthID: "2026-08-01"),
                            size: CGSize(width: 600, height: 700), dark: dark,
                            to: "usage-monthly-\(dark ? "dark" : "light").png")
            let month = UsageStatisticsModel(overview: usage, period: .monthly, monthID: "2026-08-01")
            let card = UsageShareCardModel(statistics: month, selectedID: nil, agent: .all)
            guard let data = UsageShareCardRenderer.pngData(for: card, dark: dark) else {
                fatalError("Monthly card rendering failed")
            }
            try! data.write(to: URL(fileURLWithPath: outputDirectory)
                .appendingPathComponent("usage-monthly-card-\(dark ? "dark" : "light").png"))
        }
        Renderer.render(UsageStatisticsContent(overview: usage, period: .monthly),
                        size: CGSize(width: 600, height: 700), dark: false, to: "usage-monthly-current.png")
        Renderer.render(UsageStatisticsContent(overview: usage, period: .monthly, monthID: "2026-08-01"),
                        size: CGSize(width: 500, height: 700), dark: false, to: "usage-monthly-compact.png")
        var incomplete = usage
        incomplete.codexUsage?.historyIssue = "Some Codex counter changes could not be reconciled. Recorded usage may be incomplete."
        Renderer.render(UsageStatisticsContent(overview: incomplete, period: .monthly),
                        size: CGSize(width: 600, height: 700), dark: false, to: "usage-needs-review.png")
        var pendingCodex = incomplete
        pendingCodex.codexUsage?.sourceStatus?.hasCompletedScan = false
        Renderer.render(UsageStatisticsContent(overview: pendingCodex, period: .monthly, agent: .claude),
                        size: CGSize(width: 600, height: 700), dark: false, to: "usage-claude-while-codex-imports.png")
        Renderer.render(UsageStatisticsContent(overview: usage, period: .monthly, monthID: "2026-08-01", agent: .codex),
                        size: CGSize(width: 500, height: 700), dark: true, to: "usage-monthly-codex.png")
        Renderer.render(UsageStatisticsContent(overview: usage, period: .monthly, monthID: "2026-08-01", detailsExpanded: true),
                        size: CGSize(width: 600, height: 900), dark: false, to: "usage-monthly-details.png")
        let support = UsageSupportSummary(status: UsageDataStatusModel(overview: incomplete),
            version: "0.1.0", build: "1", buildKind: "Development build", operatingSystem: "Example macOS version")
        try! support.text.write(to: URL(fileURLWithPath: outputDirectory).appendingPathComponent("support-summary-example.txt"),
                                atomically: true, encoding: .utf8)
        let partialModel = UsageStatisticsModel(overview: incomplete, period: .monthly)
        let partialCard = UsageShareCardModel(statistics: partialModel, selectedID: nil, agent: .all)
        if let data = UsageShareCardRenderer.pngData(for: partialCard, dark: false) {
            try! data.write(to: URL(fileURLWithPath: outputDirectory).appendingPathComponent("usage-card-needs-review.png"))
        }
        Renderer.render(UsageStatisticsContent(overview: usage), size: CGSize(width: 500, height: 700),
                        dark: false, to: "usage-compact.png")
        let empty = UsageOverview(usage: snapshot([]), quotaFiveHour: nil, quotaSevenDay: nil, quotaProvenance: .estimated)
        Renderer.render(UsageStatisticsContent(overview: empty), size: CGSize(width: 600, height: 700),
                        dark: false, to: "usage-empty.png")
        Renderer.render(UsageStatisticsContent(overview: empty, period: .monthly),
                        size: CGSize(width: 600, height: 700), dark: false, to: "usage-monthly-empty.png")
        exit(0)
    }
    let settingsStore = SettingsStore(defaults: renderDefaults)
    let settings = UISettings(backing: settingsStore)

    let hooksInstalled = ClaudeCodeStatus(
        agentDetected: true, agentVersion: "1.0.44",
        hooksInstalled: true, needsRepair: false
    )
    let fileActivity = ClaudeCodeStatus(
        agentDetected: true, agentVersion: "1.0.44",
        hooksInstalled: false, needsRepair: false
    )
    let needsRepair = ClaudeCodeStatus(
        agentDetected: true, agentVersion: "1.0.44",
        hooksInstalled: true, needsRepair: true
    )

    // The Settings window's own TabView tab strip is an AppKit vibrancy view;
    // the WindowServer composites its material, so cacheDisplay captures only
    // the ink on it and it comes out as a blank band (verified: every pixel in
    // that band reads alpha 0 in dark). Rather than ship a half-drawn strip,
    // each tab's REAL content view is rendered on its own, at the width the
    // window gives it and at the height the page itself asks for.
    let settingsWidth: CGFloat = 620

    if measureOnly {
        // Agents is measured in all three hero states: the hero's status line
        // is the one row on the page whose height varies with state, and the
        // window has to clear the tallest of them.
        let cases: [(String, SettingsTab, ClaudeCodeStatus)] = [
            ("general", .general, hooksInstalled),
            ("profile", .profile, hooksInstalled),
            ("agents (hooks installed)", .agents, hooksInstalled),
            ("agents (file activity)", .agents, fileActivity),
            ("agents (needs repair)", .agents, needsRepair),
            ("safety", .safety, hooksInstalled),
        ]
        func row(_ label: String, _ value: CGFloat) {
            print("  \(label.padding(toLength: 26, withPad: " ", startingAt: 0))\(Int(value)) pt")
        }
        print("SettingsTabs natural height at \(Int(settingsWidth))pt wide")
        print("(tab strip and TabView insets included — this is what the window must clear):")
        var tallest: CGFloat = 0
        for (label, tab, status) in cases {
            let height = Measure.tabHeight(tab, settings: settings, status: status, width: settingsWidth)
            row(label, height)
            tallest = max(tallest, height)
        }
        row("tallest", tallest)
        row("shipping windowHeight", SettingsView.windowHeight)
        print(SettingsView.windowHeight >= tallest
              ? "  OK — the window clears every page."
              : "  CLIPPED — the window is \(Int(tallest - SettingsView.windowHeight))pt short.")

        // The numbers say it fits; these say what it looks like. The assembled
        // SettingsView at its real frame, one image per tab, so the bottom of
        // the last card can be looked at instead of taken on trust.
        //
        // Not committed and not in the README: the tab strip is AppKit vibrancy
        // and captures as a blank band offscreen (see CAPTURE.md §3), so these
        // are a measurement instrument, not a picture of the product. Write
        // them somewhere scratch.
        print("Assembled window, \(Int(settingsWidth))x\(Int(SettingsView.windowHeight))pt:")
        for tab in [SettingsTab.general, .profile, .agents, .safety] {
            let router = SettingsTabRouter()
            router.selectedTab = tab
            let name = tab == .general ? "general" : tab == .profile ? "profile" : (tab == .agents ? "agents" : "safety")
            Renderer.render(
                SettingsView(
                    settings: settings,
                    integrations: AgentIntegrationsModel(
                        provider: StagedIntegrationsProvider(hooksInstalled)
                    ),
                    tabRouter: router,
                    profile: BrewProfileStore(defaults: renderDefaults), showProfile: {}
                ),
                size: CGSize(width: settingsWidth, height: SettingsView.windowHeight),
                dark: false,
                to: "measure-window-\(name).png"
            )
        }
        renderDefaults.removePersistentDomain(forName: renderSuiteName)
        print("done")
        exit(0)
    }

    for (dark, suffix) in [(false, "light"), (true, "dark")] {
        print("--- \(suffix) ---")

        Renderer.render(
            GeneralSettingsTab(settings: settings),
            dark: dark, width: settingsWidth,
            to: "settings-general-\(suffix).png"
        )

        let agentPages: [(ClaudeCodeStatus, String)] = [
            (hooksInstalled, "settings-agents"),
            (fileActivity, "settings-agents-fileactivity"),
            (needsRepair, "settings-agents-repair"),
        ]
        for (status, stem) in agentPages {
            Renderer.render(
                AgentsSettingsTab(
                    settings: settings,
                    integrations: AgentIntegrationsModel(provider: StagedIntegrationsProvider(status))
                ),
                dark: dark, width: settingsWidth,
                to: "\(stem)-\(suffix).png"
            )
        }

        Renderer.render(
            SafetySettingsTab(settings: settings),
            dark: dark, width: settingsWidth,
            to: "settings-safety-\(suffix).png"
        )

        // Install-consent sheet — real changes from Core, synthetic home.
        let sheetProvider = StagedIntegrationsProvider(fileActivity)
        let sheet = InstallConsentSheet(
            changes: sheetProvider.plannedChanges(),
            isRepair: false,
            onInstall: {}, onCancel: {}
        )
        Renderer.render(
            sheet, dark: dark, width: 540,
            to: "consent-sheet-\(suffix).png"
        )

        // Custom hold panel — the real window controller, both modes.
        for kind in [CustomHoldKind.duration, CustomHoldKind.endTime] {
            let controller = CustomHoldWindowController(commit: { _ in }, didClose: {})
            controller.retarget(kind)
            let name = kind == .duration ? "duration" : "until"
            if let window = controller.window {
                Renderer.renderWindow(window, dark: dark, chrome: true,
                                      to: "custom-hold-\(name)-\(suffix).png")
            }
        }

        // Onboarding — the real window controller. Step 1 is what it opens on.
        let onboardingIntegrations = AgentIntegrationsModel(provider: StagedIntegrationsProvider(fileActivity))
        let onboarding = OnboardingWindowController(
            settings: UISettings(backing: SettingsStore(defaults: renderDefaults)),
            integrations: onboardingIntegrations,
            launchAtLogin: LaunchAtLoginChoice(isEnabled: false, registrar: InertRegistrar()),
            onFinished: {}
        )
        if let window = onboarding.window {
            Renderer.renderWindow(window, dark: dark, chrome: true,
                                  to: "onboarding-step1-\(suffix).png")

        }
    }

    let absent = ClaudeCodeStatus(agentDetected: false, agentVersion: nil, hooksInstalled: false, needsRepair: false)
    for dark in [false, true] {
        let suffix = dark ? "dark" : "light"
        for (label, claude, codex) in [("both", fileActivity, CodexStatus.localSessions),
                                       ("codex", absent, CodexStatus.localSessions),
                                       ("none", absent, CodexStatus.notFound)] {
            let integrations = AgentIntegrationsModel(provider: StagedIntegrationsProvider(claude, codex: codex))
            Renderer.render(OnboardingView(
                settings: UISettings(backing: SettingsStore(defaults: renderDefaults)),
                integrations: integrations,
                launchAtLogin: LaunchAtLoginChoice(isEnabled: false, registrar: InertRegistrar()),
                finish: {}, initialStep: 1
            ), size: CGSize(width: OnboardingSizing.width, height: OnboardingSizing.height), dark: dark,
               chrome: true, title: "Welcome to Decaf", to: "onboarding-\(label)-\(suffix).png")
        }
        Renderer.render(OnboardingView(
            settings: UISettings(backing: SettingsStore(defaults: renderDefaults)),
            integrations: AgentIntegrationsModel(provider: StagedIntegrationsProvider(fileActivity)),
            launchAtLogin: LaunchAtLoginChoice(isEnabled: false, registrar: InertRegistrar()),
            finish: {}, initialStep: 2
        ), size: CGSize(width: OnboardingSizing.width, height: OnboardingSizing.height), dark: dark,
           chrome: true, title: "Welcome to Decaf", to: "onboarding-finish-\(suffix).png")
    }

    // The menu bar icon's four states, from the shipping IconRenderer. Template
    // images, so they are drawn onto a transparent canvas at both polarities.
    renderIconStrip()

    renderDefaults.removePersistentDomain(forName: renderSuiteName)
    print("done")
}

exit(0)
