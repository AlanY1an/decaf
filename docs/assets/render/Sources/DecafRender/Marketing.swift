// Repository artwork. Product views and menu copy are reused with synthetic inputs.
// These compositions are intentionally labeled as excerpts / walkthroughs, not screenshots
// of an entire menu or evidence of a running agent. No detector or power engine is started.
import AppKit
import SwiftUI
import DecafCore
import UsageMetering
import SessionTransfer

@MainActor
enum MarketingAssets {
    static func render(usage: UsageOverview) {
        let snapshot = AppStateSnapshot(fallbackAgents: [.claudeCode, .codex], wantsHold: true,
                                        hasEverDetectedAgent: true, usage: usage)
        for dark in [false, true] {
            Renderer.render(MarketingHero(usage: usage, snapshot: snapshot, dark: dark),
                            size: CGSize(width: 1280, height: 800), scale: 1, dark: dark,
                            to: "readme-hero-\(dark ? "dark" : "light").png")
        }
        Renderer.render(MarketingHero(usage: usage, snapshot: snapshot, dark: false, compact: true),
                        size: CGSize(width: 1280, height: 640), scale: 1, dark: false,
                        to: "repo-social-preview.png")
        for step in 0..<5 {
            Renderer.render(MarketingWalkthrough(usage: usage, snapshot: snapshot, step: step),
                            size: CGSize(width: 1280, height: 800), scale: 1, dark: false,
                            to: "walkthrough-\(step + 1).png")
        }
    }
}

/// Editorial status excerpt: the icon and sentence come from the real menu presenters.
private struct MarketingStatus: View {
    let snapshot: AppStateSnapshot
    let dark: Bool
    private var p: UsageStatisticsPalette { UsageStatisticsPalette(dark: dark) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("FROM YOUR MENU BAR").font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(1.6).foregroundStyle(p.secondary)
            HStack(spacing: 14) {
                Image(nsImage: IconRenderer.shared.image(for: snapshot)).scaleEffect(1.35).frame(width: 28)
                Text(MenuTextFormatter.statusLine(for: snapshot)).font(.system(size: 15, weight: .medium))
            }
            Divider().overlay(p.secondary.opacity(0.12))
            Label("Auto Keep Awake for Agents", systemImage: "checkmark")
                .font(.system(size: 13)).foregroundStyle(p.secondary)
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(p.canvas, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(p.secondary.opacity(0.18)))
    }
}

/// The complete current Home view, with isolated preferences and an empty session catalog.
@MainActor
private struct MarketingHome: View {
    let usage: UsageOverview
    let snapshot: AppStateSnapshot
    var body: some View {
        let preferences = UISettings(backing: SettingsStore(defaults: renderDefaults))
        let profile = BrewProfileStore(defaults: renderDefaults)
        let integrations = AgentIntegrationsModel(provider: StagedIntegrationsProvider(
            ClaudeCodeStatus(agentDetected: true, agentVersion: nil, hooksInstalled: true, needsRepair: false)))
        DecafWindowView(store: AppStateStore(snapshot: snapshot), settings: preferences,
            integrations: integrations, profile: profile, router: DecafWindowRouter(),
            tabRouter: SettingsTabRouter(), commands: InertCommands(), sessions: isolatedRenderSessions())
    }
}

@MainActor
func isolatedRenderSessions() -> SessionTransferModel {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("decaf-art-" + UUID().uuidString)
    let paths = SessionPaths(desktop: base.appendingPathComponent("desktop"),
        claude: base.appendingPathComponent("claude"), logs: base.appendingPathComponent("logs"))
    return SessionTransferModel(catalog: SessionCatalog(paths: paths), labelDefaults: nil,
        migrationRoot: base.appendingPathComponent("moves"))
}

private struct MarketingHero: View {
    let usage: UsageOverview
    let snapshot: AppStateSnapshot
    let dark: Bool
    var compact = false
    private var p: UsageStatisticsPalette { UsageStatisticsPalette(dark: dark) }
    var body: some View {
        HStack(spacing: compact ? 40 : 38) {
            VStack(alignment: .leading, spacing: compact ? 24 : 28) {
                Text("decaf.").font(.custom("Georgia-Bold", size: 38))
                Spacer(minLength: 0)
                Text("Your agents work.\nYour Mac\nstays awake.")
                    .font(.custom("Georgia", size: compact ? 48 : 43)).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Automatic keep-awake.\nClaude Code + Codex token stats.")
                    .font(.system(size: 18)).lineSpacing(7).foregroundStyle(p.secondary)
                if !compact { MarketingStatus(snapshot: snapshot, dark: dark) }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Free & open source · macOS 14+").font(.system(size: 13))
                    Text("Native UI · Example data").font(.system(size: 12)).foregroundStyle(p.secondary)
                }
            }.frame(width: compact ? 430 : 335)
            MarketingHome(usage: usage, snapshot: snapshot)
                .frame(width: 900, height: 840)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(p.secondary.opacity(0.2)))
                .scaleEffect(compact ? 0.70 : 0.87)
                .frame(width: compact ? 630 : 783, height: compact ? 588 : 731)
                .shadow(color: .black.opacity(dark ? 0.22 : 0.08), radius: 18, y: 8)
        }
        .padding(.horizontal, compact ? 72 : 62).padding(.vertical, compact ? 26 : 34)
        .frame(width: 1280, height: compact ? 640 : 800)
        .foregroundStyle(p.ink)
        .background(dark ? Color(red: 0.09, green: 0.09, blue: 0.082) : Color(red: 0.945, green: 0.932, blue: 0.891))
    }
}

private struct MarketingWalkthrough: View {
    let usage: UsageOverview
    let snapshot: AppStateSnapshot
    let step: Int
    private let p = UsageStatisticsPalette(dark: false)
    private let titles = ["Detect activity.\nStay awake.", "Work done.\nLet it rest.", "Both tools.\nOne usage view.", "See the whole month.", "Go deeper per tool."]
    private let subtitles = [
        "Claude Code, Codex, or both.\nAutomatic keep-awake, in your menu bar.",
        "After detection's grace or idle window.\nOther active holds still apply.",
        "Today's tokens. Both tools.\nA week of recorded activity.",
        "Browse earlier months.\nSee combined or per-tool usage.",
        "Filter Claude Code or Codex.\nInspect input, output and cached tokens."
    ]
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 60) {
                VStack(alignment: .leading, spacing: 28) {
                    Text("decaf.").font(.custom("Georgia-Bold", size: 32))
                    Spacer()
                    Text(String(format: "%02d / 05", step + 1)).font(.system(size: 12, design: .monospaced)).foregroundStyle(p.secondary)
                    Text(titles[step]).font(.custom("Georgia", size: 44)).fixedSize(horizontal: false, vertical: true)
                    Text(subtitles[step]).font(.system(size: 18)).lineSpacing(8).foregroundStyle(p.secondary)
                    Spacer()
                    Text("Staged UI walkthrough · Example data\ngithub.com/AlanY1an/decaf")
                        .font(.system(size: 11)).lineSpacing(6).foregroundStyle(p.secondary)
                }.frame(width: 450)
                Group {
                    if step < 2 {
                        VStack(spacing: 30) {
                            UsageBrewCup(ink: p.ink, fill: p.codex.opacity(0.3)).frame(width: 158, height: 164)
                            MarketingStatus(snapshot: step == 0 ? snapshot : AppStateSnapshot(hasEverDetectedAgent: true, usage: usage), dark: false)
                            Text("Menu status excerpt").font(.system(size: 12)).foregroundStyle(p.secondary)
                        }.frame(width: 480)
                    } else {
                        UsageStatisticsContent(overview: usage, period: step == 2 ? .daily : .monthly,
                                               monthID: step == 2 ? nil : "2026-08-01",
                                               agent: step == 4 ? .codex : .all)
                            .frame(width: 600, height: 740).clipShape(RoundedRectangle(cornerRadius: 18))
                            .scaleEffect(0.82).frame(width: 492, height: 607)
                    }
                }.frame(width: 520, height: 630)
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 8) {
                ForEach(0..<5) { index in
                    Capsule().fill(index == step ? p.codex : p.secondary.opacity(0.18)).frame(height: 3)
                }
            }.padding(.top, 20)
        }
        .padding(.horizontal, 76).padding(.vertical, 50)
        .frame(width: 1280, height: 800).foregroundStyle(p.ink)
        .background(Color(red: 0.945, green: 0.932, blue: 0.891))
    }
}
