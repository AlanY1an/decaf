import SwiftUI
import DecafCore
import UsageMetering

enum DecafWindowPage: Hashable { case home, sessions, settings }

@MainActor
final class DecafWindowRouter: ObservableObject {
    @Published var page: DecafWindowPage = .home
}

enum DecafMotion {
    static func page(_ reduced: Bool) -> Animation? { reduced ? nil : .easeInOut(duration: 0.22) }
    static func selection(_ reduced: Bool) -> Animation? { reduced ? nil : .spring(response: 0.28, dampingFraction: 0.92) }
    static func transition(_ reduced: Bool) -> AnyTransition {
        reduced ? .identity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 5)), removal: .opacity)
    }
}

/// The menu, reopening the app and settings shortcuts all use this one window.
struct DecafWindowView: View {
    @ObservedObject var store: AppStateStore
    @ObservedObject var settings: UISettings
    @ObservedObject var integrations: AgentIntegrationsModel
    @ObservedObject var profile: BrewProfileStore
    @ObservedObject var router: DecafWindowRouter
    @ObservedObject var tabRouter: SettingsTabRouter
    let commands: any AppCommands
    @StateObject private var sessions: SessionTransferModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var navigation
    private var palette: UsageStatisticsPalette { .init(dark: scheme == .dark) }

    init(store: AppStateStore, settings: UISettings, integrations: AgentIntegrationsModel,
         profile: BrewProfileStore, router: DecafWindowRouter, tabRouter: SettingsTabRouter,
         commands: any AppCommands, sessions: SessionTransferModel? = nil) {
        self.store = store; self.settings = settings; self.integrations = integrations
        self.profile = profile; self.router = router; self.tabRouter = tabRouter
        self.commands = commands
        _sessions = StateObject(wrappedValue: sessions ?? SessionTransferModel())
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("decaf.").font(.custom("Georgia", size: 27)).tracking(-1)
                    .padding(.horizontal, 30).padding(.top, 34).padding(.bottom, 48)
                VStack(spacing: 7) {
                    navigationButton("Home", page: .home)
                    navigationButton("Move sessions", subtitle: "Claude Code", page: .sessions)
                    navigationButton("Settings", page: .settings)
                }.padding(.horizontal, 20).animation(DecafMotion.selection(reduceMotion), value: router.page)
                Spacer()
                Button { openSettings(.profile) } label: {
                    Text(profile.nickname.isEmpty ? "Your profile" : profile.nickname)
                        .font(.system(size: 12)).lineLimit(1).foregroundStyle(palette.secondary)
                }.buttonStyle(.plain).help("Edit your profile")
                    .padding(.horizontal, 30).padding(.bottom, 30)
            }.frame(width: 174).frame(maxHeight: .infinity)
                .background(palette.selection.opacity(0.25).ignoresSafeArea(edges: .top))
            Rectangle().fill(palette.rule.opacity(0.5)).frame(width: 1)
                .ignoresSafeArea(edges: .top)
            ZStack(alignment: .topLeading) {
                // Keep pages mounted so tab switches retain filters and scroll positions.
                Group {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 32) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(profile.value.title).font(.custom("Georgia", size: 29))
                                        .lineLimit(2).minimumScaleFactor(0.7)
                                    Spacer(minLength: 16)
                                    Text(context.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                                        .font(.system(size: 12)).foregroundStyle(palette.secondary)
                                }
                                awakeStatus(now: context.date)
                                UsageStatisticsContent(overview: store.snapshot.usage, homeProfile: profile)
                            }.frame(maxWidth: 680).padding(.horizontal, 52).padding(.top, 36).padding(.bottom, 30)
                                .frame(maxWidth: .infinity)
                        }.scrollIndicators(.automatic)
                    }
                }.modifier(DecafPageVisibility(active: router.page == .home, reducedMotion: reduceMotion))
                Group {
                    DecafSettingsPane(settings: settings, integrations: integrations,
                                      profile: profile, router: tabRouter)
                }.modifier(DecafPageVisibility(active: router.page == .settings, reducedMotion: reduceMotion))
                SessionTransferView(model: sessions)
                    .modifier(DecafPageVisibility(active: router.page == .sessions, reducedMotion: reduceMotion))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(DecafMotion.page(reduceMotion), value: router.page)
        }.background(palette.canvas.ignoresSafeArea()).foregroundStyle(palette.ink).tint(palette.codex)
            .onChange(of: router.page) { _, page in
                if page == .sessions { sessions.refresh() }
            }
    }

    private func navigationButton(_ title: String, subtitle: String? = nil, page: DecafWindowPage) -> some View {
        Button { router.page = page } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: router.page == page ? .semibold : .regular))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(palette.secondary)
                    }
                }
                Spacer()
            }.padding(.horizontal, 10).frame(height: subtitle == nil ? 43 : 58)
                .foregroundStyle(router.page == page ? palette.ink : palette.secondary)
                .overlay(alignment: .leading) {
                    if router.page == page {
                        Capsule().fill(palette.codex).frame(width: 2, height: 15)
                            .matchedGeometryEffect(id: "navigation", in: navigation)
                    }
                }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(subtitle.map { title + ", " + $0 } ?? title)
            .accessibilityAddTraits(router.page == page ? .isSelected : [])
    }

    private func awakeStatus(now: Date) -> some View {
        let snapshot = store.snapshot
        return HStack(spacing: 12) {
            Circle().fill(snapshot.safetyPause != nil ? palette.claude
                          : snapshot.wantsHold ? palette.codex : palette.secondary)
                .frame(width: 6, height: 6).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                // Reuse the menu's safety, manual, hook and fallback precedence.
                Text(MenuTextFormatter.statusLine(for: snapshot, now: now))
                    .font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Button { openSettings(.agents) } label: {
                    Text(snapshot.agentAutoKeepAwake ? "Automatic keep-awake settings" : "Automatic keep-awake is off")
                        .font(.system(size: 12)).foregroundStyle(palette.secondary)
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 16)
            Button(snapshot.agentAutoKeepAwake ? "Pause auto" : "Resume auto") {
                commands.setAgentAutoKeepAwake(!snapshot.agentAutoKeepAwake)
            }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(palette.secondary)
                .help("Changes automatic agent holds only. Manual keep-awake is controlled from the menu bar.")
        }
    }

    private func openSettings(_ tab: SettingsTab) {
        tabRouter.selectedTab = tab
        router.page = .settings
    }
}

struct DecafSettingsPane: View {
    @ObservedObject var settings: UISettings
    @ObservedObject var integrations: AgentIntegrationsModel
    @ObservedObject var profile: BrewProfileStore
    @ObservedObject var router: SettingsTabRouter
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection
    private var palette: UsageStatisticsPalette { .init(dark: scheme == .dark) }
    private let tabs: [(SettingsTab, String)] = [(.general, "General"), (.agents, "Agents"), (.safety, "Safety"), (.profile, "Your profile")]

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            Text("Settings").font(.custom("Georgia", size: 29))
            HStack(spacing: 30) {
                ForEach(tabs, id: \.0) { tab, title in
                    Button { router.selectedTab = tab } label: {
                        Text(title).font(.system(size: 13, weight: .medium))
                            .foregroundStyle(router.selectedTab == tab ? palette.ink : palette.secondary)
                            .padding(.bottom, 12)
                            .overlay(alignment: .bottom) {
                                if router.selectedTab == tab {
                                    Rectangle().fill(palette.ink).frame(height: 1)
                                        .matchedGeometryEffect(id: "settings-tab", in: selection)
                                }
                            }
                    }.buttonStyle(.plain).accessibilityAddTraits(router.selectedTab == tab ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }.animation(DecafMotion.selection(reduceMotion), value: router.selectedTab)
            ScrollView {
                ZStack(alignment: .topLeading) {
                    Group {
                        switch router.selectedTab {
                        case .general: GeneralSettingsTab(settings: settings, homeLayout: true)
                        case .agents: AgentsSettingsTab(settings: settings, integrations: integrations, homeLayout: true)
                        case .safety: SafetySettingsTab(settings: settings, homeLayout: true)
                        case .profile: BrewProfileEditor(profile: profile)
                        }
                    }.id(router.selectedTab).transition(DecafMotion.transition(reduceMotion))
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 20)
            }.animation(DecafMotion.page(reduceMotion), value: router.selectedTab)
        }.frame(maxWidth: 680).padding(.horizontal, 52).padding(.top, 36).padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Uses the same history and month selection as the token panel, including gaps.
struct DecafRhythmView: View {
    let model: UsageProfileModel
    @ObservedObject var profile: BrewProfileStore
    let palette: UsageStatisticsPalette
    @State private var selectedDay: String?
    @State private var sharing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 28) { identity; Spacer(minLength: 16); grid }
                VStack(alignment: .leading, spacing: 20) { identity; grid }
            }
            if let day = model.days.first(where: { $0.id == selectedDay }) {
                Text(model.label(day.id) + " · " + UsageStatisticsModel.compact(day.tokens(for: .all).total) + " recorded tokens")
                    .font(.system(size: 11)).foregroundStyle(palette.secondary)
            }
            Text(model.isPartial ? "All agents · Partial history · Blank days may include missing records."
                 : "All agents · Local history · Blank days may include missing records.")
                .font(.system(size: 10)).foregroundStyle(palette.secondary)
        }
        .sheet(isPresented: $sharing) { BrewProfileShareSheet(profile: profile, usage: model) }
        .onChange(of: model.monthID) { _, _ in selectedDay = nil }
    }
    private var identity: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your rhythm").font(.custom("Georgia", size: 21))
            Text(model.isLoading ? "Reading local history…" : "\(model.monthActiveDays) days with usage · \(model.monthLabel)")
                .font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Share your brew") { sharing = true }.font(.system(size: 12)).buttonStyle(.plain)
                .disabled(model.isLoading || model.monthActiveDays == 0).padding(.top, 4)
        }
    }
    private var grid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.isCurrentMonth ? "Last 90 days" : "90 days to " + model.label(model.throughID))
                .font(.system(size: 10)).foregroundStyle(palette.secondary)
            BrewActivityGrid(cells: model.cells(for: model.days, showsIntensity: true), palette: palette,
                             selectedDay: selectedDay, onSelect: { selectedDay = selectedDay == $0 ? nil : $0 }, compact: true)
                .disabled(model.isLoading).allowsHitTesting(!model.isLoading)
                .accessibilityHidden(model.isLoading)
        }.fixedSize()
    }
}

struct DecafPreferenceGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            VStack(spacing: 0) { content }
        }
    }
}

struct DecafPreferenceRow<Control: View>: View {
    let title: String
    var detail: String = ""
    @ViewBuilder var control: Control
    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 14))
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }.padding(.vertical, 21).frame(minHeight: 68)
    }
}

private struct DecafPageVisibility: ViewModifier {
    let active: Bool
    let reducedMotion: Bool
    func body(content: Content) -> some View {
        content.opacity(active ? 1 : 0)
            .offset(y: active || reducedMotion ? 0 : 5)
            .allowsHitTesting(active).disabled(!active).accessibilityHidden(!active)
    }
}
