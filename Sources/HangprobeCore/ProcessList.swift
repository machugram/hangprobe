import Foundation

public struct RunningApp: Identifiable, Hashable, Codable, Sendable {
    public var pid: Int32
    public var app: String
    public var bundleID: String?
    public var place: ProbePlace
    public var serial: String?

    public var id: String { "\(place.rawValue):\(serial ?? "-"):\(pid):\(app)" }

    public init(pid: Int32, app: String, bundleID: String? = nil, place: ProbePlace, serial: String? = nil) {
        self.pid = pid
        self.app = app
        self.bundleID = bundleID
        self.place = place
        self.serial = serial
    }
}

public enum ProcessList {
    public static func current() -> [RunningApp] {
        var found: [RunningApp] = []
        var seen = Set<Int32>()
        let listing = (try? Shell.run(["/usr/bin/lsappinfo", "list"], timeout: 10).stdout) ?? ""
        for item in foreground(from: listing) {
            seen.insert(item.pid)
            found.append(item)
        }
        for (pid, command) in processes() {
            let executable = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
            if !executable.contains("CoreSimulator/Devices/") { continue }
            if !executable.contains(".app/") || executable.contains(".appex/") { continue }
            if seen.contains(pid) { continue }
            seen.insert(pid)
            found.append(RunningApp(
                pid: pid,
                app: URL(fileURLWithPath: executable).lastPathComponent,
                place: .simulator
            ))
        }
        found.append(contentsOf: AndroidDevices.running())
        found.sort { lhs, rhs in
            let left = (lhs.place == .simulator ? 0 : lhs.place == .mac ? 1 : 2, lhs.app.lowercased())
            let right = (rhs.place == .simulator ? 0 : rhs.place == .mac ? 1 : 2, rhs.app.lowercased())
            return left < right
        }
        return found
    }

    public static func foreground(from text: String) -> [RunningApp] {
        var found: [RunningApp] = []
        var current: [String: String] = [:]
        var open = false

        func flush() {
            guard open else { return }
            if current["kind"] != "Foreground" || current["terminated"] == "1" { return }
            guard let pidText = current["pid"], let pid = Int32(pidText), let app = current["app"], !app.isEmpty else { return }
            found.append(RunningApp(pid: pid, app: app, bundleID: current["bundle"], place: .mac))
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let row = String(line)
            if row.range(of: #"^\s*\d+\)\s+""#, options: .regularExpression) != nil {
                flush()
                current = [:]
                open = true
                continue
            }
            guard open else { continue }
            if row.contains("executable path="), let path = capture(row, #"executable path="([^"]+)""#) {
                current["app"] = URL(fileURLWithPath: path).lastPathComponent
            }
            if row.contains("bundleID="), let bundle = capture(row, #"bundleID="([^"]+)""#) {
                current["bundle"] = bundle
            }
            if row.contains("pid =") {
                if row.contains("terminated") { current["terminated"] = "1" }
                if let pid = capture(row, #"pid = (\d+)"#) { current["pid"] = pid }
                if let kind = capture(row, #"type="([^"]+)""#) { current["kind"] = kind }
            }
        }
        flush()
        return found
    }

    public static func processes() -> [(Int32, String)] {
        guard let text = try? Shell.run(["/bin/ps", "-axww", "-o", "pid=,command="], timeout: 10).stdout else { return [] }
        var rows: [(Int32, String)] = []
        for line in text.split(separator: "\n") {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            let parts = stripped.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            rows.append((pid, parts[1]))
        }
        return rows
    }

    static func capture(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let hit = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[hit])
    }
}
