import Foundation
import AppKit
import SessionTransfer

// Read-only census. Deliberately omits titles, paths and complete account IDs.
let appURL = URL(fileURLWithPath: "/Applications/Claude.app")
let running = NSWorkspace.shared.runningApplications.first { $0.bundleURL == appURL }
let runtime: DesktopRuntime? = running.flatMap { app in
    guard let launched = app.launchDate,
          let version = Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return nil }
    return DesktopRuntime(pid: app.processIdentifier, launchedAt: launched, version: version)
}
let inventory = SessionCatalog().scan(runtime: runtime)
let report: [String: Any] = [
    "accounts": inventory.stores.map { store in
        ["account": String(store.account.accountID.prefix(8)), "rows": store.rows.count,
         "emailAvailable": inventory.accountLabels[store.account]?.email != nil,
         "organizationNameAvailable": inventory.accountLabels[store.account]?.organization != nil,
         "issues": store.issues.map { $0.code.rawValue },
         "sessions": store.rows.map { row -> [String: String] in
             let group: String
             switch row.grouping {
             case .unknown: group = "unknown"
             case .ungrouped: group = "ungrouped"
             case .named: group = "named"
             }
             return ["status": row.issue?.code.rawValue ?? "transcriptLocated",
                     "pinStatus": row.isPinned.map { $0 ? "pinned" : "unpinned" } ?? "unknown",
                     "groupStatus": group]
         }] as [String: Any]
    },
    "issues": inventory.issues.map { $0.code.rawValue },
    "currentAccount": inventory.currentAccount.map { String($0.accountID.prefix(8)) } ?? "unknown",
    "note": "Read-only inventory. A located transcript has not yet been checked for a safe handoff."
]
if CommandLine.arguments.contains("--json"), let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
    print(String(decoding: data, as: UTF8.self))
} else {
    print("Decaf · local Claude Code sessions")
    for store in inventory.stores {
        print("\(store.account.shortName): \(store.rows.count) listings; \(store.rows.filter { $0.issue != nil }.count) need attention")
    }
    for issue in inventory.issues { print(issue.message) }
    print("Read only. Use Decaf's Sessions page to confirm the current account and preview a handoff.")
}
