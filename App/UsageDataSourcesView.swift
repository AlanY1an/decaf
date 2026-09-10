import AppKit
import SwiftUI

struct UsageDataSourcesView: View {
    let status: UsageDataStatusModel
    var timeZone: TimeZone = .current
    @State private var copySucceeded: Bool?

    private var supportSummary: UsageSupportSummary {
        #if DEBUG
        let kind = "Development build"
        #else
        let kind = "Release build"
        #endif
        return UsageSupportSummary(status: status,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            buildKind: kind, operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("A little context").font(.custom("Georgia", size: 20))
            ForEach(status.sources) { source in
                VStack(alignment: .leading, spacing: 5) {
                    Text(source.agent.title).font(.system(size: 12, weight: .semibold))
                    Text(source.status).font(.system(size: 11)).foregroundStyle(.secondary)
                    if let day = source.firstDay {
                        Text("Earliest recorded usage: \(day)")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if let read = source.snapshot?.sourceStatus?.lastReadAt {
                        Text("Last read: " + read.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: timeZone)))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if let issue = source.snapshot?.historyIssue {
                        Text(issue).font(.system(size: 11)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Divider()
            Text("Claude Code includes subagents. Codex includes archived sessions. Cached tokens are included in the totals.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Dates use \(timeZone.identifier). The earliest date is the first usage we have, not a guarantee of complete history. Missing or deleted sessions can leave gaps.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Reading time changes when Decaf reads a log, not when you open this page. These are local records, not account-wide usage or a bill.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    let item = NSPasteboardItem()
                    guard item.setString(supportSummary.text, forType: .string) else {
                        copySucceeded = false
                        return
                    }
                    NSPasteboard.general.clearContents()
                    copySucceeded = NSPasteboard.general.writeObjects([item])
                } label: {
                    Label(copySucceeded == true ? "Copied" : copySucceeded == false ? "Try copying again" : "Copy support summary",
                          systemImage: copySucceeded == true ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("Copy app and macOS versions, selected sources and import status for a support issue. Excludes token totals, usage dates, paths, session IDs, conversations and raw errors.")
                Text("Versions and import status only. Nothing is sent.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(22).frame(width: 360)
        .task(id: copySucceeded) {
            guard copySucceeded != nil else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            copySucceeded = nil
        }
    }
}
