import Foundation

public enum MetricKitHangImporter {
    public static func parse(_ data: Data, thresholdMS: Int = 250, appFallback: String? = nil) throws -> [HangReport] {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let root = json as? [String: Any] else {
            throw ProbeError("MetricKit JSON must be an object.")
        }
        if let diagnostics = root["hangDiagnostics"] as? [[String: Any]] {
            return try diagnostics.map { try parseSingle($0, rootMeta: root, thresholdMS: thresholdMS, appFallback: appFallback) }
        }
        if root["callStackTree"] != nil {
            return [try parseSingle(root, rootMeta: root, thresholdMS: thresholdMS, appFallback: appFallback)]
        }
        throw ProbeError("MetricKit JSON has no hangDiagnostics or callStackTree.")
    }

    private static func parseSingle(
        _ item: [String: Any],
        rootMeta: [String: Any],
        thresholdMS: Int,
        appFallback: String?
    ) throws -> HangReport {
        let meta = (item["diagnosticMetaData"] as? [String: Any])
            ?? (rootMeta["diagnosticMetaData"] as? [String: Any])
            ?? [:]
        let durationMS = parseDurationMS(item["hangDuration"]) ?? thresholdMS
        guard let tree = item["callStackTree"] as? [String: Any],
              let stacks = tree["callStacks"] as? [[String: Any]], !stacks.isEmpty else {
            throw ProbeError("MXHangDiagnostic has no callStacks.")
        }
        let mainStack = stacks.first(where: { ($0["threadAttributed"] as? Bool) == true }) ?? stacks[0]
        guard let roots = mainStack["callStackRootFrames"] as? [[String: Any]], !roots.isEmpty else {
            throw ProbeError("MXHangDiagnostic has no callStackRootFrames.")
        }

        let chain = heaviestChain(from: roots)
        if chain.isEmpty {
            throw ProbeError("MXHangDiagnostic callStackRootFrames are empty.")
        }

        let formatted = chain.map(formatFrame)
        let leaf = formatted.last ?? ""
        let kind = classifyLeaf(leaf, chain: formatted)
        let hung = durationMS >= thresholdMS && kind != .responsive
        let display = Array(formatted.filter { frame in
            let label = SampleClassifier.leafLabel(frame)
            return label != "start" && label != "???"
        }.suffix(16))
        let finalStack = display.isEmpty ? [leaf] : display

        let appName = (meta["bundleIdentifier"] as? String)?.split(separator: ".").last.map(String.init)
            ?? (rootMeta["appName"] as? String)
            ?? appFallback
        let bundleID = (meta["bundleIdentifier"] as? String) ?? (rootMeta["bundleIdentifier"] as? String)
        let device = meta["deviceType"] as? String
        let osVersion = meta["osVersion"] as? String
        let arch = meta["platformArchitecture"] as? String
        let commit = (meta["appBuildVersion"] as? String) ?? (rootMeta["commit"] as? String)
        let firstBinary = chain.first { ($0["binaryName"] as? String) == appName } ?? chain.last
        let uuid = firstBinary?["binaryUUID"] as? String
        let loadHex = loadAddressHex(of: firstBinary)

        let context = HangContext(
            commit: commit,
            screen: meta["regionFormat"] as? String,
            device: device,
            os: osVersion,
            arch: arch,
            loadAddress: loadHex,
            binaryUUID: uuid,
            capturedAt: (rootMeta["timeStampEnd"] as? String) ?? ISO8601DateFormatter().string(from: Date())
        )

        return HangReport(
            hung: hung,
            kind: hung ? kind : .responsive,
            mainGapMS: durationMS,
            gapAtLeast: true,
            busyMS: kind == .busy ? durationMS : 0,
            blockedMS: kind == .blocked ? durationMS : 0,
            eventWaitMS: 0,
            windowMS: durationMS,
            thresholdMS: thresholdMS,
            samples: chain.last?["sampleCount"] as? Int ?? 1,
            top: finalStack.last.map(SampleClassifier.leafLabel) ?? "",
            stack: finalStack,
            app: appName,
            bundleID: bundleID,
            place: .ios,
            note: "Imported MXHangDiagnostic (\(durationMS) ms).",
            context: context
        )
    }

    private static func heaviestChain(from frames: [[String: Any]]) -> [[String: Any]] {
        let best = frames.max { lhs, rhs in
            (lhs["sampleCount"] as? Int ?? 1) < (rhs["sampleCount"] as? Int ?? 1)
        }
        guard let best else { return [] }
        if let subs = best["subFrames"] as? [[String: Any]], !subs.isEmpty {
            return [best] + heaviestChain(from: subs)
        }
        return [best]
    }

    private static func formatFrame(_ raw: [String: Any]) -> String {
        let binary = (raw["binaryName"] as? String) ?? "unknown"
        if let symbol = raw["symbol"] as? String, !symbol.isEmpty {
            return "\(symbol) (in \(binary))"
        }
        if let address = numberHex(raw["address"]) {
            return "\(address) (in \(binary))"
        }
        if let offset = raw["offsetIntoBinaryTextSegment"] as? Int {
            return String(format: "0x%llx (in %@)", UInt64(max(0, offset)), binary)
        }
        return "??? (in \(binary))"
    }

    private static func loadAddressHex(of raw: [String: Any]?) -> String? {
        guard let raw else { return nil }
        if let address = uint64Value(raw["address"]),
           let offset = uint64Value(raw["offsetIntoBinaryTextSegment"]),
           address >= offset {
            return String(format: "0x%llx", address - offset)
        }
        return nil
    }

    private static func numberHex(_ any: Any?) -> String? {
        guard let value = uint64Value(any) else { return nil }
        return String(format: "0x%llx", value)
    }

    private static func uint64Value(_ any: Any?) -> UInt64? {
        if let intVal = any as? Int, intVal >= 0 { return UInt64(intVal) }
        if let uintVal = any as? UInt64 { return uintVal }
        if let num = any as? NSNumber { return num.uint64Value }
        if let str = any as? String {
            let trimmed = str.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("0x") {
                return UInt64(trimmed.dropFirst(2), radix: 16)
            }
            return UInt64(trimmed)
        }
        return nil
    }

    private static func classifyLeaf(_ leaf: String, chain: [String]) -> HangKind {
        let label = SampleClassifier.leafLabel(leaf)
        let waitTraps: Set<String> = [
            "mach_msg_trap", "mach_msg2_trap", "semaphore_wait_trap", "kevent", "kevent64",
            "__psynch_cvwait", "__psynch_mutexwait", "__semwait_signal", "ulock_wait",
            "nanosleep", "__select", "poll", "_dispatch_sema4_wait",
        ]
        if waitTraps.contains(label) || chain.contains(where: { $0.contains("pthread_mutex_lock") || $0.contains("dispatch_sync") || $0.contains("__ulock_wait") }) {
            let inService = chain.reversed().first {
                $0.contains("__CFRunLoopServiceMachPort") || $0.contains("__CFRUNLOOP_IS_CALLING_OUT") || $0.contains("__CFRunLoopDoSources")
            }
            if let inService, inService.contains("__CFRunLoopServiceMachPort") {
                return .responsive
            }
            return .blocked
        }
        return .busy
    }

    private static func parseDurationMS(_ raw: Any?) -> Int? {
        if let number = raw as? Double { return Int((number * 1000).rounded()) }
        if let number = raw as? Int { return number }
        if let text = raw as? String {
            let lower = text.trimmingCharacters(in: .whitespaces).lowercased()
            if lower.hasSuffix("ms"), let val = Double(lower.dropLast(2).trimmingCharacters(in: .whitespaces)) {
                return Int(val.rounded())
            }
            if lower.hasSuffix("s"), let val = Double(lower.dropLast(1).trimmingCharacters(in: .whitespaces)) {
                return Int((val * 1000).rounded())
            }
            if let val = Double(lower) {
                return Int(val.rounded())
            }
        }
        return nil
    }
}
