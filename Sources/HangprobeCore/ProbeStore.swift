import Foundation

public struct ProbeDiff: Equatable, Sendable {
    public var beforeGapMS: Int
    public var afterGapMS: Int
    public var gapDeltaMS: Int
    public var framesAdded: [String]
    public var framesRemoved: [String]

    public static func compare(_ before: HangReport, _ after: HangReport) -> ProbeDiff {
        let old = Set(before.stack)
        let new = Set(after.stack)
        return ProbeDiff(
            beforeGapMS: before.mainGapMS,
            afterGapMS: after.mainGapMS,
            gapDeltaMS: after.mainGapMS - before.mainGapMS,
            framesAdded: after.stack.filter { !old.contains($0) },
            framesRemoved: before.stack.filter { !new.contains($0) }
        )
    }
}

public struct ProbeStore {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var shared: ProbeStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return ProbeStore(root: base.appendingPathComponent("Hangprobe/history", isDirectory: true))
    }

    public func append(_ report: HangReport) throws {
        let folder = root.appendingPathComponent(slug(report.app ?? "unknown"), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = String(format: "%.0f", Date().timeIntervalSince1970 * 1000) + ".json"
        let data = try JSONEncoder().encode(report)
        try data.write(to: folder.appendingPathComponent(name))
    }

    public func reports(app: String) throws -> [HangReport] {
        let folder = root.appendingPathComponent(slug(app), isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return try urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
            try JSONDecoder().decode(HangReport.self, from: Data(contentsOf: url))
        }
    }

    public func latestPair(app: String) throws -> (HangReport, HangReport)? {
        let all = try reports(app: app)
        guard all.count >= 2 else { return nil }
        return (all[all.count - 2], all[all.count - 1])
    }

    private func slug(_ app: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let cleaned = app.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let text = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return text.isEmpty ? "unknown" : text
    }
}
