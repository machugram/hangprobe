import Foundation

public enum ReportMarkdown {
    public static func render(_ report: HangReport) -> String {
        var lines = [
            "\(report.kind.rawValue) · \(report.mainGapMS) ms off the event loop",
            report.gapAtLeast ? "The stall is at least this long." : "The thread returned to the event loop during the sample.",
        ]
        if let note = report.note { lines.append(note) }
        if let app = report.app { lines.append("App: \(app)") }
        lines.append("Stack:")
        if report.stack.isEmpty {
            lines.append("- (empty)")
        } else {
            lines.append(contentsOf: report.stack.map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }
}

public enum WatchRun {
    public static func firstHang(attempts: Int, sample: () throws -> HangReport) throws -> HangReport {
        var best: HangReport?
        let count = max(attempts, 1)
        for _ in 0..<count {
            let report = try sample()
            if best == nil || report.mainGapMS > best!.mainGapMS { best = report }
            if report.hung { return report }
        }
        if let best { return best }
        throw ProbeError("watch took no samples.")
    }
}
