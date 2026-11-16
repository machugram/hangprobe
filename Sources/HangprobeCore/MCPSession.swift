import Foundation

public enum MCPSession {
    public static let preferredVersion = "2025-06-18"
    public static let toolDescription = """
        Sample a running Mac or iOS Simulator app and report whether its main \
        thread is hung. Pass app as a pid, a bundle id, or a process name \
        such as Finder. Omit app to probe the only user app \
        in the booted Simulator. hung means the main thread spent at least \
        threshold_ms outside the UI event loop during the sample: kind busy is \
        on-CPU work such as a layout loop, kind blocked is a lock or sleep. \
        main_gap_ms is that time. gap_at_least means the thread never returned \
        to the event loop, so the stall is at least as long as the sample and \
        may have started earlier. stack is the heaviest main-thread leaf. \
        Sampling pauses the process for about a second. A physical iPhone is \
        not a local process and cannot be sampled this way. A package on a \
        connected Android device is read with adb instead of sample.
        """

    public static func handle(_ message: [String: Any], initialized: inout Bool, probe: (String?, Int, Int) throws -> HangReport) -> [String: Any]? {
        guard (message["jsonrpc"] as? String) == "2.0", let method = message["method"] as? String else {
            return error(id: message["id"], code: -32600, message: "invalid request")
        }
        if method.hasPrefix("notifications/") {
            if method == "notifications/initialized" { initialized = true }
            return nil
        }
        guard message.keys.contains("id") else { return nil }
        let requestID = message["id"] as Any
        if method == "initialize" {
            let params = message["params"] as? [String: Any] ?? [:]
            let requested = params["protocolVersion"] as? String
            let version = (requested?.count == 10) ? requested! : preferredVersion
            initialized = true
            return result(id: requestID, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "hangprobe", "version": "1"],
                "instructions": "Call probe_hang while the screen is up. Pass the app name, bundle id, or pid. Read hung, kind, main_gap_ms, and stack.",
            ])
        }
        if method == "ping" { return result(id: requestID, [:]) }
        if !initialized { return error(id: requestID, code: -32600, message: "server not initialized") }
        if method == "tools/list" { return result(id: requestID, ["tools": [tool]]) }
        if method == "tools/call" { return result(id: requestID, call(message["params"], probe: probe)) }
        return error(id: requestID, code: -32601, message: "method not found")
    }

    public static func serve(probe: (String?, Int, Int) throws -> HangReport) {
        let input = FileHandle.standardInput
        let output = FileHandle.standardOutput
        var buffer = Data()
        var initialized = false
        while true {
            let incoming: ([String: Any], String)?
            do {
                incoming = try readMessage(&buffer) {
                    let chunk = input.readData(ofLength: 4096)
                    return chunk.isEmpty ? nil : chunk
                }
            } catch {
                write(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]], framing: "line", to: output)
                continue
            }
            guard let incoming else { return }
            if let response = handle(incoming.0, initialized: &initialized, probe: probe) {
                write(response, framing: incoming.1, to: output)
            }
        }
    }

    public static func readMessage(_ buffer: inout Data, read: () -> Data?) throws -> ([String: Any], String)? {
        while true {
            if buffer.isEmpty {
                guard let chunk = read() else { return nil }
                buffer.append(chunk)
            }
            if buffer.first == 0x0d || buffer.first == 0x0a {
                while let first = buffer.first, first == 0x0d || first == 0x0a { buffer.removeFirst() }
                continue
            }
            if buffer.first == UInt8(ascii: "{") {
                guard let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) else {
                    guard let chunk = read() else { return nil }
                    buffer.append(chunk)
                    continue
                }
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                let object = try jsonObject(Data(line))
                return (object, "line")
            }
            return try readLSP(&buffer, read: read)
        }
    }

    private static func readLSP(_ buffer: inout Data, read: () -> Data?) throws -> ([String: Any], String)? {
        let marker = Data("\r\n\r\n".utf8)
        while buffer.range(of: marker) == nil {
            guard let chunk = read() else { return nil }
            buffer.append(chunk)
        }
        guard let range = buffer.range(of: marker) else { return nil }
        let header = String(data: buffer.subdata(in: buffer.startIndex..<range.lowerBound), encoding: .utf8) ?? ""
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        var length: Int?
        for line in header.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            length = Int(line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "")
        }
        guard let length else { throw ProbeError("missing Content-Length") }
        while buffer.count < length {
            guard let chunk = read() else { return nil }
            buffer.append(chunk)
        }
        let body = buffer.prefix(length)
        buffer.removeFirst(length)
        return (try jsonObject(Data(body)), "lsp")
    }

    public static func encode(_ object: [String: Any], framing: String) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        if framing == "lsp" {
            var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
            data.append(body)
            return data
        }
        var data = body
        data.append(UInt8(ascii: "\n"))
        return data
    }

    private static func write(_ object: [String: Any], framing: String, to output: FileHandle) {
        var payload = object
        if payload["id"] is NSNull { payload["id"] = NSNull() }
        try? output.write(contentsOf: encode(payload, framing: framing))
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        let trimmed = data.filter { $0 != 0x0d && $0 != 0x0a }
        guard let object = try JSONSerialization.jsonObject(with: trimmed) as? [String: Any] else {
            throw ProbeError("invalid request")
        }
        return object
    }

    private static var tool: [String: Any] {
        [
            "name": "probe_hang",
            "title": "Probe a running app for a hang",
            "description": toolDescription,
            "inputSchema": [
                "type": "object",
                "additionalProperties": false,
                "properties": [
                    "app": ["type": "string", "description": "Pid, bundle id, or process name. Omit for the booted Simulator app."],
                    "seconds": ["type": "integer", "minimum": 1, "maximum": 3, "description": "How long to sample. Default 1."],
                    "threshold_ms": ["type": "integer", "minimum": 50, "maximum": 3000, "description": "Off-loop main-thread time that counts as a hang. Default 250."],
                ],
            ],
        ]
    }

    private static func call(_ params: Any?, probe: (String?, Int, Int) throws -> HangReport) -> [String: Any] {
        guard let params = params as? [String: Any] else { return toolError("Invalid tool call.") }
        guard (params["name"] as? String) == "probe_hang" else { return toolError("Unknown tool.") }
        guard let arguments = params["arguments"] as? [String: Any] else { return toolError("Arguments must be an object.") }
        let extra = Set(arguments.keys).subtracting(["app", "seconds", "threshold_ms"]).sorted()
        if !extra.isEmpty { return toolError("Rejected unknown fields: \(extra.joined(separator: ", ")).") }
        let app = arguments["app"]
        if let app, !(app is String) { return toolError("app must be a string.") }
        let seconds = intValue(arguments["seconds"]) ?? 1
        let threshold = intValue(arguments["threshold_ms"]) ?? 250
        do {
            let report = try probe(app as? String, seconds, threshold)
            let encoded = try JSONEncoder().encode(report)
            let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
            let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            let text = String(data: pretty, encoding: .utf8) ?? ""
            return ["content": [["type": "text", "text": text]], "structuredContent": object, "isError": false]
        } catch {
            return toolError(String(describing: error))
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.intValue }
        return nil
    }

    private static func result(id: Any, _ value: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": value]
    }

    private static func error(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    private static func toolError(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }
}
