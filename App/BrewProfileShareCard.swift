import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Used unchanged in the share preview and PNG export.
struct BrewProfileShareCard: View {
    let model: BrewProfileShareModel
    @Environment(\.colorScheme) private var scheme
    private var palette: UsageStatisticsPalette { UsageStatisticsPalette(dark: scheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            HStack(alignment: .firstTextBaseline) {
                Text("decaf.").font(.custom("Georgia-Bold", size: 22))
                Spacer()
                Text(model.monthLabel).font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.secondary)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(model.title).font(.custom("Georgia", size: 27)).lineLimit(2).minimumScaleFactor(0.6)
                    Text(model.blend).font(.system(size: 11, weight: .medium)).foregroundStyle(palette.codex)
                }
                Spacer(minLength: 0)
                BrewAvatarView(avatar: model.avatar, palette: palette).frame(width: 76, height: 76)
            }
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(model.activeDays)").font(.system(size: 74, weight: .regular, design: .rounded)).monospacedDigit().tracking(-2)
                    Text("days with usage").font(.system(size: 12)).foregroundStyle(palette.secondary)
                    Text(model.throughLabel).font(.system(size: 9, design: .monospaced)).foregroundStyle(palette.secondary).padding(.top, 9)
                }
                Spacer()
                BrewMonthCalendar(cells: model.cells, calendarDays: model.calendarDays,
                                  palette: palette, showsIntensity: model.total != nil)
            }
            if let total = model.total {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(UsageStatisticsModel.compact(total)).font(.system(size: 30, design: .rounded)).monospacedDigit()
                    Text("recorded tokens").font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
            }
            HStack(spacing: 24) {
                ForEach(model.agents) { agent in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Circle().fill(agent.isCodex ? palette.codex : palette.claude).frame(width: 6, height: 6)
                            Text(agent.name).font(.system(size: 11, weight: .medium))
                        }
                        if let count = agent.tokens {
                            Text(UsageStatisticsModel.compact(count)).font(.system(size: 14, design: .rounded)).monospacedDigit()
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            UsageReceiptRule().stroke(palette.rule, style: StrokeStyle(lineWidth: 1, dash: [3, 4])).frame(height: 1)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text("brewed with Decaf").font(.custom("Georgia", size: 13))
                    Spacer()
                    Text("github.com/AlanY1an/decaf").font(.system(size: 10, design: .monospaced))
                }
                Text(model.isPartial ? "Partial local history · Some records need attention"
                     : model.total == nil ? "Activity only · Blank days may include missing history"
                     : "Local tokens · Includes cache · Blank days may include missing history")
                    .font(.system(size: 9)).foregroundStyle(palette.secondary)
            }
        }
        .padding(32).frame(width: 500)
        .background(palette.canvas).foregroundStyle(palette.ink)
    }
}

@MainActor
enum BrewProfileShareRenderer {
    static func pngData(for model: BrewProfileShareModel, dark: Bool) -> Data? {
        guard model.isReady else { return nil }
        let renderer = ImageRenderer(content: BrewProfileShareCard(model: model)
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func copy(_ model: BrewProfileShareModel, dark: Bool) -> Bool {
        guard let data = pngData(for: model, dark: dark) else { return false }
        let item = NSPasteboardItem()
        guard item.setData(data, forType: .png) else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([item])
    }
}

struct BrewProfileShareSheet: View {
    enum Appearance: String, CaseIterable {
        case system = "System", light = "Light", dark = "Dark"
    }
    @ObservedObject var profile: BrewProfileStore
    let usage: UsageProfileModel
    @State private var message: String?
    @State var appearance: Appearance = .system
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    private var model: BrewProfileShareModel { BrewProfileShareModel(profile: profile.value, usage: usage) }
    private var cardIsDark: Bool { appearance == .dark || (appearance == .system && scheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("A month to keep.").font(.custom("Georgia", size: 21))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                if usage.isLoading {
                    VStack(spacing: 14) {
                        ProgressView().controlSize(.small)
                        Text("Refreshing local history…").font(.system(size: 12))
                        Text("Your card will be ready when the totals settle.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }.frame(width: 500, height: 440)
                } else {
                    BrewProfileShareCard(model: model)
                        .environment(\.colorScheme, cardIsDark ? .dark : .light)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }.frame(maxHeight: 550)
            HStack {
                Toggle("Show token totals", isOn: $profile.showsTokenTotals)
                    .font(.system(size: 12)).toggleStyle(.checkbox)
                    .onChange(of: profile.showsTokenTotals) { _, _ in message = nil }
                Spacer()
                Picker("Card appearance", selection: $appearance) {
                    ForEach(Appearance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 188)
                .accessibilityLabel("Card appearance").help("Appearance of the exported card")
                .onChange(of: appearance) { _, _ in message = nil }
            }
            HStack {
                Text(message ?? "Made on your Mac. Share it when you’re ready.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Save PNG…") { save() }.disabled(!model.isReady)
                Button("Copy card") {
                    message = BrewProfileShareRenderer.copy(model, dark: cardIsDark) ? "Copied to clipboard" : "Couldn’t copy. Try again."
                }.keyboardShortcut(.defaultAction).disabled(!model.isReady)
            }
        }
        .padding(24).frame(width: 548)
        .task(id: message) {
            guard message != nil else { return }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            message = nil
        }
    }

    private func save() {
        guard let data = BrewProfileShareRenderer.pngData(for: model, dark: cardIsDark) else {
            message = "Couldn’t render the card. Try again."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = model.filename
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic); message = "Saved" }
        catch { message = "Couldn’t save. Choose another location." }
    }
}
