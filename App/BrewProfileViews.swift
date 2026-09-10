import SwiftUI

struct BrewAvatarView: View {
    let avatar: BrewAvatar
    let palette: UsageStatisticsPalette
    var body: some View {
        ZStack {
            Circle().fill(palette.selection)
            Circle().strokeBorder(palette.rule, style: StrokeStyle(lineWidth: 1, dash: [2, 4])).padding(4)
            if avatar == .cup {
                UsageBrewCup(ink: palette.claude, fill: palette.cup).padding(13).rotationEffect(.degrees(-7))
            } else {
                Image(systemName: avatar.symbol).font(.system(size: 31, weight: .light))
                    .foregroundStyle(avatar == .moon ? palette.codex : palette.claude)
            }
        }
        .accessibilityHidden(true)
    }
}

struct BrewActivityGrid: View {
    let cells: [BrewActivityCell]
    let palette: UsageStatisticsPalette
    var showsIntensity = true
    var selectedDay: String? = nil
    var onSelect: ((String) -> Void)? = nil
    var compact = false
    private var side: CGFloat { compact ? 15 : 22 }

    var body: some View {
        let weeks = BrewActivityCell.weeks(cells)
        HStack(alignment: .top, spacing: compact ? 6 : 7) {
            VStack(spacing: 5) {
                Color.clear.frame(width: 12, height: 12)
                ForEach(0..<7) { day in
                    Text(["M", "", "W", "", "F", "", ""][day])
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(palette.secondary)
                        .frame(width: 12, height: side)
                }
            }.accessibilityHidden(true)
            HStack(alignment: .top, spacing: 5) {
                ForEach(weeks.indices, id: \.self) { week in
                    VStack(spacing: 5) {
                        let month = weeks[week].compactMap { $0 }.first { $0.day.hasSuffix("-01") }
                            ?? (week == 0 ? weeks[week].compactMap { $0 }.first : nil)
                        Text(month?.monthLabel ?? "").font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(palette.secondary).fixedSize(horizontal: true, vertical: false)
                            .frame(width: side, height: 12)
                        ForEach(0..<7) { day in
                            if let cell = weeks[week][day] {
                                if let onSelect {
                                    Button { onSelect(cell.day) } label: { square(cell) }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(cell.label + (cell.hasUsage ? ", recorded usage" : ", no recorded usage"))
                                        .accessibilityAddTraits(cell.day == selectedDay ? .isSelected : [])
                                        .help(cell.label + (cell.hasUsage ? " · Recorded usage" : " · No recorded usage; history may be missing"))
                                } else {
                                    square(cell).accessibilityLabel(cell.label + (cell.hasUsage ? ", recorded usage" : ", no recorded usage"))
                                }
                            } else {
                                Color.clear.frame(width: side, height: side).accessibilityHidden(true)
                            }
                        }
                    }.frame(width: side)
                }
            }
        }
    }

    private func square(_ cell: BrewActivityCell) -> some View {
        RoundedRectangle(cornerRadius: compact ? 3 : 5)
            .fill(cell.hasUsage ? palette.codex.opacity(showsIntensity ? 0.25 + Double(cell.level) * 0.1875 : 0.85) : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 3 : 5)
                    .strokeBorder(cell.day == selectedDay ? palette.ink : palette.rule.opacity(cell.hasUsage ? 0 : 0.65),
                                  lineWidth: cell.day == selectedDay ? 1.5 : 1)
            }
            .frame(width: side, height: side)
    }
}

/// A calendar for the shared month. Future dates are faint dots; days with
/// no recorded usage are outlined squares. Neither contributes to activity.
struct BrewMonthCalendar: View {
    let cells: [BrewActivityCell]
    let calendarDays: Int
    let palette: UsageStatisticsPalette
    var showsIntensity: Bool

    var body: some View {
        let offset = cells.first?.weekday ?? 0
        let count = ((offset + calendarDays + 6) / 7) * 7
        VStack(spacing: 7) {
            HStack(spacing: 5) {
                ForEach(Array(["M", "T", "W", "T", "F", "S", "S"].enumerated()), id: \.offset) { _, label in
                    Text(label).font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(palette.secondary).frame(width: 17)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(17), spacing: 5), count: 7), spacing: 5) {
                ForEach(0..<count, id: \.self) { index in
                    let day = index - offset
                    if cells.indices.contains(day) {
                        let cell = cells[day]
                        RoundedRectangle(cornerRadius: 3)
                            .fill(cell.hasUsage ? palette.codex.opacity(showsIntensity ? 0.25 + Double(cell.level) * 0.1875 : 0.85) : Color.clear)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(palette.rule.opacity(cell.hasUsage ? 0 : 0.7)))
                            .frame(width: 17, height: 17)
                            .accessibilityLabel(cell.label + (cell.hasUsage ? ", recorded usage" : ", no recorded usage"))
                    } else if day >= 0 && day < calendarDays {
                        Circle().fill(palette.rule.opacity(0.7)).frame(width: 3, height: 3)
                            .frame(width: 17, height: 17).accessibilityHidden(true)
                    } else {
                        Color.clear.frame(width: 17, height: 17).accessibilityHidden(true)
                    }
                }
            }
        }.frame(width: 149)
    }
}

struct BrewProfileEditor: View {
    @ObservedObject var profile: BrewProfileStore
    @Environment(\.colorScheme) private var scheme
    private var palette: UsageStatisticsPalette { UsageStatisticsPalette(dark: scheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 18) {
                BrewAvatarView(avatar: profile.avatar, palette: palette).frame(width: 78, height: 78)
                VStack(alignment: .leading, spacing: 5) {
                    Text(profile.value.title).font(.custom("Georgia", size: 25)).lineLimit(2).minimumScaleFactor(0.6)
                    Text("A little more you.").font(.system(size: 12)).foregroundStyle(palette.secondary)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Nickname").font(.system(size: 12, weight: .medium))
                TextField("What should we call you?", text: $profile.nickname)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Profile nickname")
                Text("Optional · up to 32 characters").font(.system(size: 10)).foregroundStyle(palette.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Pick your cup").font(.system(size: 12, weight: .medium))
                HStack(spacing: 12) {
                    ForEach(BrewAvatar.allCases) { avatar in
                        Button { profile.avatar = avatar } label: {
                            VStack(spacing: 7) {
                                Image(systemName: avatar.symbol).font(.system(size: 20, weight: .light))
                                    .frame(height: 25)
                                Text(avatar.title).font(.system(size: 10))
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(profile.avatar == avatar ? palette.selection : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(profile.avatar == avatar ? palette.claude : palette.rule, lineWidth: 1))
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(avatar.title)
                        .accessibilityAddTraits(profile.avatar == avatar ? .isSelected : [])
                    }
                }
            }
            Toggle("Show token totals on shared cards", isOn: $profile.showsTokenTotals)
                .font(.system(size: 12)).toggleStyle(.checkbox)
            Text("With totals hidden, cards show days with usage and your tools. Your name and choices stay on this Mac until you share a card.")
                .font(.system(size: 11)).foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(palette.ink).tint(palette.claude)
    }
}

struct ProfileSettingsTab: View {
    @ObservedObject var profile: BrewProfileStore
    var showProfile: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                BrewProfileEditor(profile: profile)
                Button(action: showProfile) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Open Your brew").font(.system(size: 13, weight: .medium))
                            Text("Your activity, your tools, a monthly card to keep.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .padding(18).background(UsageStatisticsPalette(dark: scheme == .dark).selection, in: RoundedRectangle(cornerRadius: 14))
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain)
            }
            .padding(28)
        }
    }
}
