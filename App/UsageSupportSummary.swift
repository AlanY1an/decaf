import Foundation

/// An allowlist for the text users may choose to attach to a support issue.
/// Never serializes snapshots or raw issue text: those can contain metadata
/// that is useful inside the app but does not belong in a public report.
struct UsageSupportSummary {
    let text: String

    init(status: UsageDataStatusModel, version: String, build: String, buildKind: String, operatingSystem: String) {
        var lines = ["Decaf usage support summary", "Version: \(version) (\(build)) · \(buildKind)",
                     "macOS: \(operatingSystem)", "Scope: \(status.sources.map { $0.agent.title }.joined(separator: " + "))"]
        for source in status.sources {
            let issue = source.snapshot?.historyIssue != nil
            let phase = (source.isReading || source.snapshot == nil && status.isLoading) ? "Reading local history" : issue ? "Needs attention" : source.status
            lines.append("")
            lines.append("\(source.agent.title): \(phase)")
            if let count = source.snapshot?.sourceStatus?.filesRead {
                lines.append("Local logs read this run: \(count)")
            }
            lines.append("Import issue detected: \(issue ? "yes" : "no")")
        }
        lines.append("")
        lines.append("Excluded: token totals, usage dates, file paths, session IDs, conversation text and raw errors.")
        text = lines.joined(separator: "\n")
    }
}
