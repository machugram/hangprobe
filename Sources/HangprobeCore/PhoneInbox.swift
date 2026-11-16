import Foundation
import Network

public struct PhoneInboxStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var shared: PhoneInboxStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return PhoneInboxStore(root: base.appendingPathComponent("Hangprobe/inbox", isDirectory: true))
    }

    @discardableResult
    public func save(_ report: HangReport) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stamp = String(format: "%.0f", Date().timeIntervalSince1970 * 1000)
        let slug = sanitize(report.app ?? "device")
        let url = root.appendingPathComponent("\(stamp)-\(slug)-\(UUID().uuidString.prefix(6)).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url)
        try ProbeStore.shared.append(report)
        return url
    }

    public func allReports(limit: Int = 50) -> [HangReport] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let sorted = urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        let decoder = JSONDecoder()
        return sorted.prefix(limit).compactMap { try? decoder.decode(HangReport.self, from: Data(contentsOf: $0)) }
    }

    private func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let chars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let cleaned = String(chars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "device" : cleaned
    }
}

public enum RegressionGate {
    public struct Verdict: Equatable, Sendable {
        public var passed: Bool
        public var baselineGapMS: Int?
        public var candidateGapMS: Int
        public var deltaMS: Int?
        public var maxGapMS: Int
        public var maxRegressionMS: Int
        public var reason: String
    }

    public static func evaluate(
        baseline: HangReport?,
        candidate: HangReport,
        maxGapMS: Int = 250,
        maxRegressionMS: Int = 50
    ) -> Verdict {
        let delta = baseline.map { candidate.mainGapMS - $0.mainGapMS }
        if candidate.hung || candidate.mainGapMS >= maxGapMS {
            return Verdict(
                passed: false,
                baselineGapMS: baseline?.mainGapMS,
                candidateGapMS: candidate.mainGapMS,
                deltaMS: delta,
                maxGapMS: maxGapMS,
                maxRegressionMS: maxRegressionMS,
                reason: "Candidate crossed hang budget (\(candidate.mainGapMS) ms >= \(maxGapMS) ms, kind \(candidate.kind.rawValue))."
            )
        }
        if let delta, delta > maxRegressionMS {
            return Verdict(
                passed: false,
                baselineGapMS: baseline?.mainGapMS,
                candidateGapMS: candidate.mainGapMS,
                deltaMS: delta,
                maxGapMS: maxGapMS,
                maxRegressionMS: maxRegressionMS,
                reason: "Main-thread gap regressed by +\(delta) ms (limit +\(maxRegressionMS) ms)."
            )
        }
        return Verdict(
            passed: true,
            baselineGapMS: baseline?.mainGapMS,
            candidateGapMS: candidate.mainGapMS,
            deltaMS: delta,
            maxGapMS: maxGapMS,
            maxRegressionMS: maxRegressionMS,
            reason: "Within budget (\(candidate.mainGapMS) ms < \(maxGapMS) ms)."
        )
    }
}

public enum ReportExporter {
    public static func markdown(_ report: HangReport) -> String {
        var lines = [
            "### Hangprobe: `\(report.kind.rawValue)` (\(report.mainGapMS) ms off the event loop)",
            "",
            "- **App**: `\(report.app ?? "unknown")`\(report.bundleID.map { " (`\($0)`)" } ?? "")",
            "- **Where**: `\(report.place?.rawValue ?? "mac")`",
            "- **Top frame**: `\(report.top)`",
        ]
        if let ctx = report.context {
            if let commit = ctx.commit { lines.append("- **Commit / Build**: `\(commit)`") }
            if let screen = ctx.screen { lines.append("- **Screen**: `\(screen)`") }
            if let device = ctx.device { lines.append("- **Device**: `\(device)`\(ctx.os.map { " (\($0))" } ?? "")") }
        }
        if let note = report.note { lines.append("- **Note**: \(note)") }
        lines += ["", "```text"] + report.stack + ["```"]
        return lines.joined(separator: "\n")
    }

    public static func prettyJSON(_ report: HangReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }
}

public final class PhoneInboxServer: @unchecked Sendable {
    public let port: UInt16
    /// When true (default), accept connections only on the loopback interface.
    public let localhostOnly: Bool
    /// Optional shared secret. When set, `POST /v1/hangs` and `GET /v1/hangs` require
    /// `Authorization: Bearer <token>` or `X-Hangprobe-Token: <token>`.
    public let authToken: String?
    public let dsymPath: String?
    public let ndkSymbolsPath: String?
    public let store: PhoneInboxStore
    private var listener: NWListener?
    private let onReport: (@Sendable (HangReport) -> Void)?

    public init(
        port: UInt16 = 9481,
        localhostOnly: Bool = true,
        authToken: String? = nil,
        dsymPath: String? = nil,
        ndkSymbolsPath: String? = nil,
        store: PhoneInboxStore = .shared,
        onReport: (@Sendable (HangReport) -> Void)? = nil
    ) {
        self.port = port
        self.localhostOnly = localhostOnly
        self.authToken = authToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.dsymPath = dsymPath
        self.ndkSymbolsPath = ndkSymbolsPath
        self.store = store
        self.onReport = onReport
    }

    public var listenURL: String {
        let host = localhostOnly ? "127.0.0.1" : "0.0.0.0"
        return "http://\(host):\(port)/v1/hangs"
    }

    public func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ProbeError("Invalid port \(port).")
        }
        let parameters = NWParameters.tcp
        if localhostOnly {
            parameters.requiredInterfaceType = .loopback
        }
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.service = NWListener.Service(name: "Hangprobe", type: "_hangprobe._tcp")
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: DispatchQueue(label: "com.hangprobe.inbox"))
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "com.hangprobe.inbox.conn"))
        readHTTPRequest(connection: connection, accumulated: Data())
    }

    private func readHTTPRequest(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = accumulated
            if let chunk { buffer.append(chunk) }
            if let parsed = Self.parseHTTP(buffer) {
                let response = self.route(
                    method: parsed.method,
                    path: parsed.path,
                    headers: parsed.headers,
                    body: parsed.body
                )
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }
            if isComplete || error != nil || buffer.count > 2_000_000 {
                let response = Self.httpResponse(status: "400 Bad Request", json: #"{"error":"incomplete request"}"#)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            self.readHTTPRequest(connection: connection, accumulated: buffer)
        }
    }

    public func ingestPayload(_ body: Data) throws -> [HangReport] {
        var decoded: [HangReport] = []
        if let report = try? JSONDecoder().decode(HangReport.self, from: body) {
            decoded = [report]
        } else {
            decoded = try MetricKitHangImporter.parse(body)
        }
        var saved: [HangReport] = []
        for raw in decoded {
            let symbolicated = Symbolicator.symbolicateReport(raw, dsymPath: dsymPath, ndkSymbolsPath: ndkSymbolsPath)
            _ = try store.save(symbolicated)
            onReport?(symbolicated)
            saved.append(symbolicated)
        }
        return saved
    }

    private func route(method: String, path: String, headers: [String: String], body: Data) -> Data {
        if method == "GET" && (path == "/health" || path == "/") {
            let bind = localhostOnly ? "loopback" : "all"
            return Self.httpResponse(
                status: "200 OK",
                json: #"{"ok":true,"service":"hangprobe-inbox","bind":"\#(bind)","auth":\#(authToken == nil ? "false" : "true")}"#
            )
        }
        if needsAuth(path: path), !isAuthorized(headers: headers) {
            return Self.httpResponse(status: "401 Unauthorized", json: #"{"error":"missing or invalid token"}"#)
        }
        if method == "GET" && path == "/v1/hangs" {
            let reports = store.allReports(limit: 25)
            let data = (try? JSONEncoder().encode(reports)) ?? Data("[]".utf8)
            return Self.httpResponse(status: "200 OK", body: data)
        }
        if method == "POST" && (path == "/v1/hangs" || path == "/v1/metrickit") {
            do {
                let saved = try ingestPayload(body)
                let payload = #"{"accepted":\#(saved.count),"top":"\#(saved.first?.top ?? "")"}"#
                return Self.httpResponse(status: "202 Accepted", json: payload)
            } catch {
                let escaped = String(describing: error).replacingOccurrences(of: "\"", with: "'")
                return Self.httpResponse(status: "400 Bad Request", json: #"{"error":"\#(escaped)"}"#)
            }
        }
        return Self.httpResponse(status: "404 Not Found", json: #"{"error":"not found"}"#)
    }

    private func needsAuth(path: String) -> Bool {
        guard authToken != nil else { return false }
        return path == "/v1/hangs" || path == "/v1/metrickit"
    }

    private func isAuthorized(headers: [String: String]) -> Bool {
        guard let expected = authToken else { return true }
        if let bearer = headers["authorization"], bearer.lowercased().hasPrefix("bearer ") {
            let token = bearer.dropFirst("bearer ".count).trimmingCharacters(in: .whitespaces)
            return token == expected
        }
        if let header = headers["x-hangprobe-token"] {
            return header == expected
        }
        return false
    }

    static func parseHTTP(_ buffer: Data) -> (method: String, path: String, headers: [String: String], body: Data)? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else { return nil }
        guard let headerText = String(data: buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound), encoding: .utf8) else {
            return nil
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var contentLength = 0
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
            if name == "content-length", let val = Int(value) {
                contentLength = max(0, val)
            }
        }
        let bodyStart = headerEnd.upperBound
        let available = buffer.count - bodyStart
        guard available >= contentLength else { return nil }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        return (String(parts[0]), String(parts[1]), headers, body)
    }

    private static func httpResponse(status: String, json: String) -> Data {
        httpResponse(status: status, body: Data(json.utf8))
    }

    private static func httpResponse(status: String, body: Data) -> Data {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(body)
        return out
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
