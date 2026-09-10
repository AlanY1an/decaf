import AppKit
import SwiftUI

/// The exact view copied by the app and rendered for documentation.
struct UsageShareCard: View {
    let model: UsageShareCardModel
    @Environment(\.colorScheme) private var scheme
    private var palette: UsageStatisticsPalette { UsageStatisticsPalette(dark: scheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .firstTextBaseline) {
                Text("decaf.").font(.custom("Georgia-Bold", size: 24))
                Spacer()
                Text(model.dateLabel).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.secondary)
            }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.title).font(.custom("Georgia", size: 23))
                    Text(UsageStatisticsModel.compact(model.total))
                        .font(.system(size: 70, weight: .regular, design: .rounded))
                        .tracking(-3).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    Text("recorded tokens").font(.system(size: 12)).foregroundStyle(palette.secondary)
                }
                Spacer(minLength: 0)
                UsageBrewCup(ink: palette.claude, fill: palette.cup)
                    .frame(width: 104, height: 108).rotationEffect(.degrees(-8))
            }
            HStack(spacing: 24) {
                ForEach(model.entries) { entry in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 6) {
                            Circle().fill(entry.agent == .claude ? palette.claude : palette.codex)
                                .frame(width: 6, height: 6)
                            Text(entry.agent.title).font(.system(size: 12, weight: .medium))
                        }
                        Text(UsageStatisticsModel.compact(entry.tokens))
                            .font(.system(size: 23, design: .rounded)).monospacedDigit()
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            UsageReceiptRule().stroke(palette.rule, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .frame(height: 1)
            VStack(alignment: .leading, spacing: 7) {
                Text("github.com/AlanY1an/decaf").font(.system(size: 12, weight: .medium, design: .monospaced))
                Text(model.isPartial ? "Partial local records · Some usage needs review" : "Local tokens · Includes cache · Not a subscription quota")
                    .font(.system(size: 10)).foregroundStyle(palette.secondary)
            }
        }
        .padding(36).frame(width: 540)
        .background(palette.canvas).foregroundStyle(palette.ink)
    }
}

@MainActor
enum UsageShareCardRenderer {
    static func pngData(for model: UsageShareCardModel, dark: Bool) -> Data? {
        let renderer = ImageRenderer(content: UsageShareCard(model: model)
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func copy(_ model: UsageShareCardModel, dark: Bool) -> Bool {
        // Finish rendering before replacing the user's clipboard.
        guard let data = pngData(for: model, dark: dark) else { return false }
        let item = NSPasteboardItem()
        guard item.setData(data, forType: .png) else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([item])
    }
}
