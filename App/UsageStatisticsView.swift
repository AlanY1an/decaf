import SwiftUI
import UsageMetering

struct UsageStatisticsView: View {
    @ObservedObject var store: AppStateStore
    @ObservedObject var profile: BrewProfileStore
    @ObservedObject var router: UsagePageRouter
    var body: some View {
        UsageDashboardContent(overview: store.snapshot.usage, profile: profile, router: router)
    }
}

enum UsagePage: String, CaseIterable, Identifiable {
    case usage, profile
    var id: String { rawValue }
    var title: String { self == .usage ? "Usage" : "Your brew" }
}

@MainActor
final class UsagePageRouter: ObservableObject {
    @Published var page: UsagePage
    init(page: UsagePage = .usage) { self.page = page }
}

struct UsageDashboardContent: View {
    let overview: UsageOverview?
    @ObservedObject var profile: BrewProfileStore
    @ObservedObject var router: UsagePageRouter
    var now: Date = Date()
    var timeZone: TimeZone = .current
    @Environment(\.colorScheme) private var scheme
    private var palette: UsageStatisticsPalette { UsageStatisticsPalette(dark: scheme == .dark) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(UsagePage.allCases) { page in
                    Button { router.page = page } label: {
                        Text(page.title).font(.system(size: 11, weight: router.page == page ? .semibold : .regular))
                            .padding(.horizontal, 15).padding(.vertical, 7)
                            .foregroundStyle(router.page == page ? palette.ink : palette.secondary)
                            .background(router.page == page ? palette.selection : Color.clear, in: Capsule())
                    }.buttonStyle(.plain).accessibilityAddTraits(router.page == page ? .isSelected : [])
                }
                Spacer()
            }.padding(.horizontal, 38).padding(.top, 14).padding(.bottom, 4)
            if router.page == .profile {
                UsageProfileContent(overview: overview, profile: profile, now: now, timeZone: timeZone)
            } else {
                UsageStatisticsContent(overview: overview)
            }
        }.background(palette.canvas)
    }
}

/// Production observes the menu's usage snapshot; the renderer injects example data.
struct UsageStatisticsContent: View {
    let overview: UsageOverview?
    var homeProfile: BrewProfileStore?
    private var homeLayout: Bool { homeProfile != nil }
    @Namespace private var periodSelection
    @State private var agent: UsageStatisticsAgent
    @State private var selectedID: String?
    @State private var period: UsageStatisticsPeriod
    @State private var monthID: String?

    init(overview: UsageOverview?, period: UsageStatisticsPeriod = .daily, monthID: String? = nil,
         agent: UsageStatisticsAgent = .all, detailsExpanded: Bool = false, homeProfile: BrewProfileStore? = nil) {
        self.overview = overview
        self.homeProfile = homeProfile
        _period = State(initialValue: period)
        _agent = State(initialValue: agent)
        _detailsExpanded = State(initialValue: detailsExpanded)
        _monthID = State(initialValue: monthID)
    }
    @State private var detailsExpanded: Bool
    @State private var copyResult: Bool?
    @State private var showingSources = false
    @State private var showingHomeSources = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dataStatus: UsageDataStatusModel { model.dataStatus(for: agent) }
    private var isLoading: Bool { dataStatus.isLoading }
    private var insights: UsagePeriodInsights { model.insights(for: agent) }
    private var palette: UsageStatisticsPalette { UsageStatisticsPalette(dark: scheme == .dark) }
    private var model: UsageStatisticsModel {
        UsageStatisticsModel(overview: overview, period: period, monthID: monthID)
    }
    private var selected: UsageStatisticsDay? { model.selectedDay(selectedID) }
    private var summary: UsageStatisticsDay { model.selection(selectedID) }
    private var tokens: TokenTotals { summary.tokens(for: agent) }
    private var isToday: Bool { selected?.id == model.todayID }
    private var isMonthSummary: Bool { period == .monthly && selected == nil }
    private var isDefaultSelection: Bool {
        agent == .all && (period == .daily ? isToday : isMonthSummary && model.isCurrentMonth)
    }
    private var brewTitle: String {
        if isMonthSummary {
            return model.isCurrentMonth ? "This month's brew" : model.dateLabel(model.monthID, format: "MMMM") + "'s brew"
        }
        return isToday ? "Today's brew" : model.dateLabel(summary.id, format: "MMMM d") + "'s brew"
    }

    private var brewSubtitle: String {
        if isLoading { return "Warming up…" }
        if tokens.total == 0 {
            return isMonthSummary ? "No usage recorded this month"
                : isToday ? "No usage recorded today" : "No usage recorded for this day"
        }
        if isMonthSummary { return "tokens · " + insights.activeDaysText }
        return agent == .all ? "tokens · \(isToday ? "one day at a time" : "a day in the life")"
            : "tokens · " + agent.title
    }

    var body: some View {
        Group {
            if homeLayout {
                sections
            } else {
                ScrollView {
                    sections.padding(.horizontal, 38).padding(.top, 28).padding(.bottom, 26)
                        .frame(maxWidth: 650).frame(maxWidth: .infinity)
                }.frame(minWidth: 500, minHeight: 540)
            }
        }
        .background(palette.canvas).foregroundStyle(palette.ink).tint(palette.claude)
        .task(id: copyResult) {
            guard copyResult != nil else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            copyResult = nil
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: homeLayout ? 23 : 20) {
            if !homeLayout { header }
            periodPicker
            dailyBrew
            agents
            if homeLayout, dataStatus.issue != nil {
                Button { showingHomeSources = true } label: {
                    Label(dataStatus.headline(timeZone: model.calendar.timeZone), systemImage: "exclamationmark.circle")
                        .font(.system(size: 11)).foregroundStyle(palette.claude)
                }.buttonStyle(.plain)
                    .popover(isPresented: $showingHomeSources) {
                        UsageDataSourcesView(status: dataStatus, timeZone: model.calendar.timeZone)
                    }
            }
            if !homeLayout { receiptRule }
            activity
            receiptRule
            if let homeProfile {
                DecafRhythmView(model: UsageProfileModel(overview: overview, monthID: period == .monthly ? model.monthID : nil),
                                profile: homeProfile, palette: palette)
            }
            details
            footer
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("decaf.").font(.custom("Georgia-Bold", size: 24))
            Spacer()
            Button {
                change { selectedID = nil; monthID = nil; agent = .all }
            } label: {
                HStack(spacing: 6) {
                    if !isDefaultSelection {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 10))
                    }
                    Text(isDefaultSelection
                         ? (period == .monthly ? "This month" : model.dateLabel(model.todayID, format: "EEE, MMM d"))
                         : (period == .monthly ? "Back to this month" : "Back to today"))
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(palette.secondary).padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(period == .monthly ? "Show this month for both agents" : "Show today for both agents")
        }
    }

    private var periodPicker: some View {
        HStack(spacing: 12) {
            if homeLayout {
                Text(brewTitle.replacingOccurrences(of: "brew", with: "tokens"))
                    .font(.system(size: 13)).foregroundStyle(palette.secondary).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 8)
            }
            HStack(spacing: 2) {
                ForEach(UsageStatisticsPeriod.allCases) { item in
                    Button {
                        change { period = item; selectedID = nil; copyResult = nil }
                    } label: {
                        Text(item.title).font(.system(size: 11, weight: period == item ? .semibold : .regular))
                            .padding(.horizontal, 13).padding(.vertical, 7)
                            .foregroundStyle(period == item ? palette.ink : palette.secondary)
                            .background(!homeLayout && period == item ? palette.selection : Color.clear, in: Capsule())
                            .overlay(alignment: .bottom) {
                                if homeLayout && period == item {
                                    Rectangle().fill(palette.ink).frame(height: 1)
                                        .matchedGeometryEffect(id: "period", in: periodSelection)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(period == item ? .isSelected : [])
                }
            }
            if !homeLayout { Spacer(minLength: 0) }
            if period == .monthly {
                monthButton("Previous month", icon: "chevron.left", destination: model.previousMonthID)
                Text(model.monthLabel).font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .accessibilityAddTraits(.updatesFrequently)
                monthButton("Next month", icon: "chevron.right", destination: model.nextMonthID)
            }
        }
    }

    private func monthButton(_ title: String, icon: String, destination: String?) -> some View {
        Button {
            change { monthID = destination; selectedID = nil; copyResult = nil }
        } label: {
            Image(systemName: icon).font(.system(size: 10, weight: .medium))
                .frame(width: 22, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(destination == nil)
        .opacity(destination == nil ? 0.25 : 1)
        .accessibilityLabel(title).help(title)
    }

    private var dailyBrew: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                if !homeLayout {
                    Text(brewTitle).font(.custom("Georgia", size: 23))
                }
                Text(isLoading ? "—" : UsageStatisticsModel.compact(tokens.total))
                    .font(.system(size: homeLayout ? 68 : 72, weight: homeLayout ? .light : .regular, design: homeLayout ? .default : .rounded))
                    .tracking(-3).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .accessibilityLabel(isLoading ? "Loading usage" : "\(tokens.total) recorded tokens")
                    .help("\(tokens.total.formatted()) recorded tokens, including cached tokens")
                if !homeLayout || isLoading || tokens.total == 0 {
                    Text(brewSubtitle).font(.system(size: 12)).foregroundStyle(palette.secondary)
                }
            }
            Spacer(minLength: 0)
            if !homeLayout {
                UsageBrewCup(ink: palette.claude, fill: palette.cup)
                    .frame(width: 116, height: 120).rotationEffect(.degrees(-8)).accessibilityHidden(true)
            }
        }
        .padding(.vertical, 9)
    }

    @ViewBuilder private var agents: some View {
        if homeLayout {
            HStack(spacing: 28) {
                homeAgentButton(.claude, count: summary.claude.total)
                homeAgentButton(.codex, count: summary.codex.total)
                Spacer(minLength: 0)
            }
        } else {
            VStack(spacing: 15) {
                HStack(spacing: 28) {
                    agentButton(.claude, count: summary.claude.total)
                    agentButton(.codex, count: summary.codex.total)
                }
                GeometryReader { geometry in
                    let total = model.isLoading ? 0 : summary.tokens(for: .all).total
                    let fraction = total > 0 ? Double(summary.claude.total) / Double(total) : 0
                    HStack(spacing: total > 0 && fraction > 0 && fraction < 1 ? 3 : 0) {
                        if fraction > 0 {
                            Capsule().fill(palette.claude.opacity(agent == .codex ? 0.25 : 1))
                                .frame(width: max(0, geometry.size.width - (fraction < 1 ? 3 : 0)) * fraction)
                        }
                        Capsule().fill(total == 0 ? palette.rule : palette.codex.opacity(agent == .claude ? 0.25 : 1))
                    }
                }.frame(height: 5).accessibilityHidden(true)
            }
        }
    }


    private func homeAgentButton(_ source: UsageStatisticsAgent, count: Int) -> some View {
        let sourceLoading = model.dataStatus(for: source).isLoading
        return Button { change { agent = agent == source ? .all : source } } label: {
            HStack(spacing: 7) {
                Circle().fill(source == .claude ? palette.claude : palette.codex).frame(width: 5, height: 5)
                Text(source.title).foregroundStyle(palette.secondary)
                Text(sourceLoading ? "—" : UsageStatisticsModel.compact(count)).monospacedDigit()
            }.font(.system(size: 12)).padding(.vertical, 4)
                .opacity(agent == .all || agent == source ? 1 : 0.45).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(agent == source ? .isSelected : [])
            .help(sourceLoading ? "Reading local history" : "\(count.formatted()) recorded tokens. Click to filter this agent.")
    }

    private func agentButton(_ source: UsageStatisticsAgent, count: Int) -> some View {
        let tint = source == .claude ? palette.claude : palette.codex
        let sourceLoading = model.dataStatus(for: source).isLoading
        let total = summary.tokens(for: .all).total
        let fraction = total > 0 ? Double(count) / Double(total) : 0
        return Button {
            change { agent = agent == source ? .all : source }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(tint).frame(width: 6, height: 6)
                    Text(source.title).font(.system(size: 12, weight: .medium))
                    if agent == source {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(tint)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(sourceLoading ? "—" : UsageStatisticsModel.compact(count))
                        .font(.system(size: 23, weight: .regular, design: .rounded)).monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                    Text(!model.isLoading && total > 0 ? "\(Int((fraction * 100).rounded()))%" : "—")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(palette.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(agent != .all && agent != source ? 0.5 : 1).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sourceLoading ? "\(source.title), reading local history" : "\(source.title), \(count) recorded tokens")
        .accessibilityAddTraits(agent == source ? .isSelected : [])
        .help(agent == source ? "Show both agents" : "Show only \(source.title)")
    }

    private var activityTitle: String {
        guard period == .monthly else { return "The last 7 days" }
        guard !isLoading, let average = insights.averagePerActiveDay else { return "A little every day" }
        return UsageStatisticsModel.compact(average) + " per active day"
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text(activityTitle)
                    .font(.system(size: 12, weight: .medium))
                    .help(period == .monthly
                          ? "Average across days with recorded usage for the selected agents. Days without records are excluded; this does not imply complete history."
                          : "Recorded usage over the last seven local calendar days")
                Spacer()
                Button {
                    change { selectedID = nil }
                } label: {
                    HStack(spacing: 5) {
                        if period == .monthly && selected != nil {
                            Image(systemName: "arrow.uturn.backward").font(.system(size: 9))
                        }
                        Text(isLoading ? "—" : "\(UsageStatisticsModel.compact(model.periodTotal(for: agent))) \(period == .monthly ? "this month" : "tokens")")
                    }
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(palette.secondary)
                }
                .buttonStyle(.plain)
                .help(period == .monthly ? "Show the month total" : "Show today")
            }
            usageChart
        }
    }

    private var usageChart: some View {
        let maximum = max(1, model.days.map { $0.tokens(for: agent).total }.max() ?? 0)
        return HStack(alignment: .bottom, spacing: period == .monthly ? 3 : 10) {
            ForEach(model.days) { day in dayBar(day, maximum: maximum) }
        }
        .overlay(alignment: .top) {
            if isLoading || model.periodTotal(for: agent) == 0 {
                VStack(spacing: 5) {
                    Text(isLoading ? "Putting the kettle on…" : (period == .monthly ? "No brews recorded." : "First sip awaits."))
                        .font(.custom("Georgia-Italic", size: 18))
                    Text(dataStatus.emptyMessage(isToday: isToday, isMonth: period == .monthly))
                        .font(.system(size: 11)).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(palette.secondary).padding(.top, 15).allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Daily recorded tokens. Select a date to see that day's usage.")
    }

    private func dayBar(_ day: UsageStatisticsDay, maximum: Int) -> some View {
        let claude = isLoading || agent == .codex ? 0 : day.claude.total
        let codex = isLoading || agent == .claude ? 0 : day.codex.total
        let chosen = day.id == selected?.id
        let future = day.id > model.todayID
        let number = Int(day.id.suffix(2)) ?? 0
        let showLabel = period == .daily || [1, 7, 14, 21].contains(number) || day.id == model.days.last?.id
        let barOpacity = isMonthSummary || chosen ? 1.0 : 0.48
        return Button {
            change { selectedID = period == .monthly && chosen ? nil : day.id }
        } label: {
            VStack(spacing: 10) {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    VStack(spacing: 0) {
                        Rectangle().fill(palette.codex).frame(height: CGFloat(codex) / CGFloat(maximum) * 88)
                        Rectangle().fill(palette.claude).frame(height: CGFloat(claude) / CGFloat(maximum) * 88)
                    }
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6))
                    .frame(maxWidth: period == .monthly ? 12 : 25).opacity(barOpacity)
                    if claude + codex == 0 { Capsule().fill(palette.rule).frame(maxWidth: period == .monthly ? 8 : 17).frame(height: 3) }
                }
                .frame(height: 88)
                Color.clear.frame(height: 22).overlay {
                    if showLabel || chosen {
                        Text(model.dateLabel(day.id, format: period == .monthly ? "d" : "EEE"))
                            .font(.system(size: period == .monthly ? 9 : 10, weight: chosen ? .semibold : .regular))
                            .foregroundStyle(chosen ? palette.ink : palette.secondary)
                            .padding(.horizontal, period == .monthly ? 3 : 7).padding(.vertical, 4)
                            .background(chosen ? palette.selection : Color.clear, in: Capsule())
                            .fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(future || isLoading).opacity(future ? 0.28 : 1)
        .help(isLoading ? "Reading local history…" : future ? "\(model.dateLabel(day.id, format: "MMM d")): upcoming"
              : "\(model.dateLabel(day.id, format: "MMM d")): \(day.tokens(for: agent).total.formatted()) recorded tokens")
        .accessibilityLabel(isLoading ? "Reading local history" : "\(model.dateLabel(day.id, format: "MMMM d")), \(future ? "upcoming" : "\(day.tokens(for: agent).total) recorded tokens")")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button {
                change { detailsExpanded.toggle() }
            } label: {
                HStack {
                    Text("The little details").font(.system(size: 12))
                    Spacer()
                    if !isLoading, let cache = UsagePeriodInsights.cacheReadText(tokens) {
                        Text(cache).font(.system(size: 10)).monospacedDigit()
                    }
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium))
                        .rotationEffect(.degrees(detailsExpanded ? 180 : 0))
                }
                .foregroundStyle(palette.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(detailsExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Show or hide input, output and cache token counts")
            if detailsExpanded {
                VStack(spacing: 12) {
                    tokenRow("Input · uncached", count: tokens.input)
                    tokenRow("Output", count: tokens.output)
                    tokenRow("Cache read", count: tokens.cacheRead)
                    tokenRow("Cache write", count: tokens.cacheCreation)
                    Text("Cache reads are reused input tokens as a share of all recorded tokens. This percentage is not a cost saving or a measure of productivity.")
                        .font(.system(size: 11)).foregroundStyle(palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if isToday, agent != .codex, let overview, overview.quotaFiveHour != nil || overview.quotaSevenDay != nil,
                       let line = UsageCopy.quotaLine(for: overview) {
                        Text("Claude Code · \(line)").font(.system(size: 11)).foregroundStyle(palette.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func tokenRow(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(palette.secondary)
            Spacer()
            Text(isLoading ? "—" : count.formatted()).monospacedDigit()
        }
        .font(.system(size: 12)).accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count) tokens")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { showingSources.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: dataStatus.issue == nil ? "info.circle" : "exclamationmark.circle")
                    Text(dataStatus.headline(timeZone: model.calendar.timeZone))
                    if let first = dataStatus.firstDay, dataStatus.issue == nil, !dataStatus.isLoading,
                       !dataStatus.noLocalLogs {
                        Text("· records since " + model.dateLabel(first, format: "MMM d, yyyy"))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 9))
                }
                .font(.system(size: 10))
                .foregroundStyle(dataStatus.issue == nil ? palette.secondary : palette.claude)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Data sources. " + dataStatus.headline(timeZone: model.calendar.timeZone))
            .accessibilityHint("Show each agent's read status and earliest recorded date")
            .popover(isPresented: $showingSources, arrowEdge: .bottom) {
                UsageDataSourcesView(status: dataStatus, timeZone: model.calendar.timeZone)
            }
            footerActions
        }
    }

    private var footerActions: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock").font(.system(size: 9))
            Text("Local logs · Cached tokens included").font(.system(size: 10))
            Image(systemName: "info.circle").font(.system(size: 11))
                .help("Counts cover recorded sessions on this Mac, using its time zone. They are not account-wide usage or subscription limits; missing sessions are not included.")
                .accessibilityLabel("Usage information: recorded sessions on this Mac, using its time zone. Counts are not account-wide usage or subscription limits. Missing sessions are not included.")
            Spacer(minLength: 8)
            Button {
                guard !isLoading else { return }
                let card = UsageShareCardModel(statistics: model, selectedID: selectedID, agent: agent)
                copyResult = UsageShareCardRenderer.copy(card, dark: scheme == .dark)
            } label: {
                Label(copyResult == true ? "Copied!" : copyResult == false ? "Try again" : "Copy card",
                      systemImage: copyResult == true ? "checkmark" : "square.on.square")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(palette.selection, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .help(copyResult == false ? "The card could not be copied. Click to try again."
                  : "Copy an image with the selected date and displayed agents' token totals. No project names or conversations. Nothing is uploaded.")
        }
        .foregroundStyle(palette.secondary)
    }

    private var receiptRule: some View {
        UsageReceiptRule().stroke(palette.rule, style: StrokeStyle(lineWidth: 1, dash: homeLayout ? [] : [3, 4]))
            .frame(height: 1).accessibilityHidden(true)
    }

    private func change(_ update: () -> Void) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            update()
            copyResult = nil
        }
    }
}

struct UsageReceiptRule: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

/// Decorative only: its size and fill do not imply a token target or quota.
struct UsageBrewCup: View {
    let ink: Color
    let fill: Color
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 116, size.height / 120)
            context.scaleBy(x: scale, y: scale)
            let stroke = StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
            var handle = Path()
            handle.move(to: CGPoint(x: 88, y: 50))
            handle.addCurve(to: CGPoint(x: 86, y: 78), control1: CGPoint(x: 119, y: 43), control2: CGPoint(x: 116, y: 78))
            context.stroke(handle, with: .color(ink), style: stroke)

            var cup = Path()
            cup.move(to: CGPoint(x: 23, y: 44))
            cup.addLine(to: CGPoint(x: 91, y: 44))
            cup.addLine(to: CGPoint(x: 85, y: 82))
            cup.addCurve(to: CGPoint(x: 32, y: 83), control1: CGPoint(x: 80, y: 108), control2: CGPoint(x: 38, y: 107))
            cup.closeSubpath()
            context.fill(cup, with: .color(fill))
            context.stroke(cup, with: .color(ink), style: stroke)

            var saucer = Path()
            saucer.move(to: CGPoint(x: 19, y: 103))
            saucer.addQuadCurve(to: CGPoint(x: 98, y: 103), control: CGPoint(x: 58, y: 115))
            context.stroke(saucer, with: .color(ink), style: stroke)

            for x in [44.0, 67.0] {
                var steam = Path()
                steam.move(to: CGPoint(x: x, y: 32))
                steam.addCurve(to: CGPoint(x: x + 1, y: 9), control1: CGPoint(x: x - 10, y: 22), control2: CGPoint(x: x + 9, y: 19))
                context.stroke(steam, with: .color(ink.opacity(0.45)), style: stroke)
            }

            var face = Path()
            face.move(to: CGPoint(x: 44, y: 64))
            face.addLine(to: CGPoint(x: 44, y: 68))
            face.move(to: CGPoint(x: 70, y: 64))
            face.addLine(to: CGPoint(x: 70, y: 68))
            face.move(to: CGPoint(x: 51, y: 77))
            face.addQuadCurve(to: CGPoint(x: 63, y: 77), control: CGPoint(x: 57, y: 84))
            context.stroke(face, with: .color(ink), style: stroke)
        }
    }
}

struct UsageStatisticsPalette {
    let dark: Bool
    var canvas: Color { Color(nsColor: DecafWindowAppearance.canvas(dark: dark)) }
    var ink: Color { dark ? Color(red: 0.95, green: 0.925, blue: 0.86) : Color(red: 0.24, green: 0.235, blue: 0.20) }
    var secondary: Color { dark ? Color(red: 0.66, green: 0.64, blue: 0.59) : Color(red: 0.49, green: 0.47, blue: 0.41) }
    var rule: Color { dark ? Color.white.opacity(0.17) : Color(red: 0.79, green: 0.76, blue: 0.68) }
    var selection: Color { dark ? Color.white.opacity(0.09) : Color(red: 0.935, green: 0.909, blue: 0.85) }
    var claude: Color { dark ? Color(red: 0.91, green: 0.57, blue: 0.38) : Color(red: 0.77, green: 0.43, blue: 0.28) }
    var codex: Color { dark ? Color(red: 0.63, green: 0.71, blue: 0.50) : Color(red: 0.48, green: 0.56, blue: 0.37) }
    var cup: Color { dark ? Color(red: 0.28, green: 0.205, blue: 0.15) : Color(red: 0.969, green: 0.86, blue: 0.70) }
}
