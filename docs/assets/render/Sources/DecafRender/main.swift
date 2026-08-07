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
        to filename: String
    ) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        NSApp.appearance = appearance
        window.appearance = appearance

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
                tabRouter: router
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
    init(_ status: ClaudeCodeStatus) { self.status = status }

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

// MARK: - Run

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)   // never a foreground app, never a Dock tile

MainActor.assumeIsolated {
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
        for tab in [SettingsTab.general, .agents, .safety] {
            let router = SettingsTabRouter()
            router.selectedTab = tab
            let name = tab == .general ? "general" : (tab == .agents ? "agents" : "safety")
            Renderer.render(
                SettingsView(
                    settings: settings,
                    integrations: AgentIntegrationsModel(
                        provider: StagedIntegrationsProvider(hooksInstalled)
                    ),
                    tabRouter: router
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
            // Steps 2 and 3 are NOT rendered. `step` is @State private inside
            // OnboardingWindow.swift's fileprivate OnboardingView, so it cannot
            // be set from here, and a synthesised click on "Continue" does not
            // route: SwiftUI hit-testing needs the window on screen, and this
            // window deliberately never is. Tried and verified — the capture
            // came back byte-identical to step 1. Do not re-add it without
            // checking the output actually changed.
        }
    }

    // The menu bar icon's four states, from the shipping IconRenderer. Template
    // images, so they are drawn onto a transparent canvas at both polarities.
    renderIconStrip()

    renderDefaults.removePersistentDomain(forName: renderSuiteName)
    print("done")
}

exit(0)
