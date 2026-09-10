import SwiftUI
import UsageMetering

struct UsageProfileContent: View {
    let overview: UsageOverview?
    @ObservedObject var profile: BrewProfileStore
    let now: Date
    let timeZone: TimeZone
    @State private var monthID: String?

    init(overview: UsageOverview?, profile: BrewProfileStore, now: Date = Date(), timeZone: TimeZone = .current,
         monthID: String? = nil) {
        self.overview = overview
        self.profile = profile
        self.now = now
        self.timeZone = timeZone
        _monthID = State(initialValue: monthID)
    }

    var body: some View {
        UsageProfilePage(profile: profile, timeZone: timeZone,
                         model: UsageProfileModel(overview: overview, now: now, timeZone: timeZone, monthID: monthID),
                         selectMonth: { monthID = $0 })
    }
}

/// Keep transient interactions below the aggregation boundary: selecting a
/// square or opening a sheet does not need to rebuild the history model.
private struct UsageProfilePage: View {
    @ObservedObject var profile: BrewProfileStore
    let timeZone: TimeZone
    let model: UsageProfileModel
    let selectMonth: (String?) -> Void
    @State private var selectedDay: String?
    @State private var editing = false
    @State private var sharing = false
    @State private var showingSources = false
    @Environment(\.colorScheme) private var scheme
    private var palette: UsageStatisticsPalette { UsageStatisticsPalette(dark: scheme == .dark) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text("decaf.").font(.custom("Georgia-Bold", size: 22))
                    Spacer()
                    Button { editing = true } label: {
                        Label("Personalize", systemImage: "pencil").font(.system(size: 11))
                    }.buttonStyle(.plain).foregroundStyle(palette.secondary)
                }
                identity
                monthReview
                rule
                activity
                usual
                footer
            }
            .padding(.horizontal, 38).padding(.vertical, 22)
            .frame(maxWidth: 650).frame(maxWidth: .infinity)
        }
        .frame(minWidth: 500, minHeight: 540)
        .background(palette.canvas).foregroundStyle(palette.ink).tint(palette.claude)
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 24) {
                BrewProfileEditor(profile: profile)
                HStack { Spacer(); Button("Done") { editing = false }.keyboardShortcut(.defaultAction) }
            }
            .padding(28).frame(width: 430).background(palette.canvas)
        }
        .sheet(isPresented: $sharing) {
            BrewProfileShareSheet(profile: profile, usage: model)
        }
        .onChange(of: model.monthID) { _, _ in selectedDay = nil }
    }

    private var identity: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text(profile.value.title).font(.custom("Georgia", size: 30))
                    .lineLimit(2).minimumScaleFactor(0.6).help(profile.value.title)
                Text("One day at a time.").font(.system(size: 12)).foregroundStyle(palette.secondary)
                HStack(spacing: 5) {
                    Image(systemName: model.month.claude.total > 0 && model.month.codex.total > 0 ? "cup.and.saucer.fill" : "leaf")
                    Text(model.blend)
                }
                .font(.system(size: 10, weight: .medium)).foregroundStyle(palette.codex)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(palette.codex.opacity(0.10), in: Capsule())
            }
            Spacer(minLength: 0)
            BrewAvatarView(avatar: profile.avatar, palette: palette).frame(width: 92, height: 92)
        }
    }

    private var monthReview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.monthLabel).font(.system(size: 11, weight: .medium, design: .monospaced))
                    Text(model.isLoading ? "Reading history…" : model.isPartial ? "Partial history"
                         : model.isCurrentMonth ? "so far" : "a month in review")
                        .font(.system(size: 10)).foregroundStyle(palette.secondary)
                }
                Spacer()
                if !model.isCurrentMonth {
                    Button("This month") { selectMonth(nil) }
                        .font(.system(size: 10)).buttonStyle(.plain)
                        .foregroundStyle(palette.secondary).padding(.trailing, 4)
                        .help("Return to the current month")
                }
                monthButton("Previous month", icon: "chevron.left", destination: model.previousMonthID)
                monthButton("Next month", icon: "chevron.right", destination: model.nextMonthID)
            }
            HStack(alignment: .top, spacing: 16) {
                metric(model.isLoading ? "—" : "\(model.monthActiveDays)", label: "days with usage")
                metric(model.isLoading ? "—" : UsageStatisticsModel.compact(model.month.tokens(for: .all).total), label: "recorded tokens")
                metric(model.isLoading ? "—" : model.highestDay.map { model.label($0.id) } ?? "—", label: "most tokens on")
            }
            if !model.isLoading && model.monthActiveDays == 0 {
                Text(model.status.emptyMessage(isToday: false, isMonth: true))
                    .font(.system(size: 11)).foregroundStyle(palette.secondary)
            }
        }
    }

    private func monthButton(_ title: String, icon: String, destination: String?) -> some View {
        Button { if let destination { selectMonth(destination) } } label: {
            Image(systemName: icon).font(.system(size: 10, weight: .medium))
                .frame(width: 26, height: 26)
                .background(palette.selection, in: Circle()).contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(destination == nil || model.isLoading)
        .opacity(destination == nil || model.isLoading ? 0.35 : 1)
        .help(title).accessibilityLabel(title)
    }

    private func metric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.system(size: 27, weight: .regular, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 10)).foregroundStyle(palette.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                Text("A little, often.").font(.custom("Georgia", size: 18))
                Spacer()
                Text(model.isCurrentMonth ? "Last 90 days" : "90 days to " + model.label(model.throughID))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.secondary)
            }
            BrewActivityGrid(cells: model.cells(for: model.days, showsIntensity: true), palette: palette,
                             selectedDay: selectedDay, onSelect: { selectedDay = selectedDay == $0 ? nil : $0 })
                .frame(maxWidth: .infinity)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if model.isLoading {
                        Text("Reading local history…")
                    } else if let day = model.days.first(where: { $0.id == selectedDay }) {
                        Text(model.label(day.id) + " · " + (day.tokens(for: .all).total > 0
                            ? UsageStatisticsModel.compact(day.tokens(for: .all).total) + " recorded tokens" : "No recorded usage"))
                    } else {
                        Text("\(model.activeDays) days with recorded usage")
                    }
                    Text("Blank days may include missing history.").font(.system(size: 9))
                }
                Spacer()
                HStack(spacing: 3) {
                    Text("Less").padding(.trailing, 3)
                    ForEach(1...4, id: \.self) { level in
                        RoundedRectangle(cornerRadius: 2).fill(palette.codex.opacity(0.25 + Double(level) * 0.1875)).frame(width: 8, height: 8)
                    }
                    Text("More").padding(.leading, 3)
                }.font(.system(size: 9)).accessibilityLabel("Color intensity shows relative recorded token use")
            }
            .font(.system(size: 10)).foregroundStyle(palette.secondary)
        }
    }

    private var usual: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Your usual").font(.system(size: 12, weight: .medium))
                Spacer()
                Text(model.isCurrentMonth ? "This month’s tokens" : model.label(model.monthID, format: "MMMM") + "’s tokens")
                    .font(.system(size: 10)).foregroundStyle(palette.secondary)
            }
            let total = model.isLoading ? 0 : model.month.tokens(for: .all).total
            let fraction = total > 0 ? Double(model.month.claude.total) / Double(total) : 0
            GeometryReader { geo in
                HStack(spacing: 3) {
                    if fraction > 0 { Capsule().fill(palette.claude).frame(width: (geo.size.width - (fraction < 1 ? 3 : 0)) * fraction) }
                    if fraction < 1 { Capsule().fill(total > 0 && !model.isLoading ? palette.codex : palette.rule) }
                }.opacity(model.isLoading ? 0.3 : 1)
            }.frame(height: 5).accessibilityHidden(true)
            HStack {
                mixLabel("Claude Code", fraction: fraction, tint: palette.claude, hasUsage: total > 0)
                Spacer()
                mixLabel("Codex", fraction: 1 - fraction, tint: palette.codex, hasUsage: total > 0)
            }
        }
    }

    private func mixLabel(_ name: String, fraction: Double, tint: Color, hasUsage: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(name)
            Text(model.isLoading || !hasUsage ? "—" : "\(Int((fraction * 100).rounded()))%")
                .foregroundStyle(palette.secondary).monospacedDigit()
        }.font(.system(size: 11))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 13) {
            Button { sharing = true } label: {
                HStack {
                    Text("Make a monthly card").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Image(systemName: "square.and.arrow.up").font(.system(size: 13))
                }
                .padding(.horizontal, 16).padding(.vertical, 13)
                .background(palette.selection, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain).disabled(model.isLoading || model.monthActiveDays == 0)
            HStack(alignment: .top) {
                Text("Local records · Includes cached tokens")
                Spacer()
                Button(model.isPartial ? "Review data sources" : "Data sources") { showingSources = true }
                    .buttonStyle(.plain).underline()
                    .popover(isPresented: $showingSources) { UsageDataSourcesView(status: model.status, timeZone: timeZone) }
            }
            .font(.system(size: 9)).foregroundStyle(palette.secondary)
        }
    }

    private var rule: some View {
        UsageReceiptRule().stroke(palette.rule, style: StrokeStyle(lineWidth: 1, dash: [3, 4])).frame(height: 1).accessibilityHidden(true)
    }
}
