import Foundation

public enum SampleClassifier {
    public static func classify(_ text: String, thresholdMS: Int) throws -> HangReport {
        let interval = try interval(in: text)
        let root = try mainThread(in: text)
        let leaves = Self.leaves(root, ancestors: [])
        var accounted = 0
        var busy = 0
        var blocked = 0
        var waiting = 0
        var tagged: [(String, Int, [String])] = []
        for (weight, chain) in leaves {
            let leafKind = kind(of: chain)
            tagged.append((leafKind, weight, chain))
            accounted += weight
            switch leafKind {
            case "busy": busy += weight
            case "blocked": blocked += weight
            default: waiting += weight
            }
        }
        let missing = root.count - accounted
        if missing > 0 { busy += missing }
        let busyMS = busy * interval
        let blockedMS = blocked * interval
        let waitMS = waiting * interval
        let offLoop = busyMS + blockedMS
        let verdict: HangKind
        if offLoop >= thresholdMS && blockedMS >= busyMS {
            verdict = .blocked
        } else if offLoop >= thresholdMS {
            verdict = .busy
        } else {
            verdict = .responsive
        }
        let chosen: (String, Int, [String])?
        switch verdict {
        case .responsive:
            chosen = heaviest(tagged, kind: nil)
        case .blocked:
            chosen = heaviest(tagged, kind: "blocked") ?? heaviest(tagged, kind: nil)
        case .busy:
            chosen = heaviest(tagged, kind: "busy") ?? heaviest(tagged, kind: nil)
        }
        let stack = chosen.map { displayStack($0.2) } ?? []
        let hotspots = extractHotspots(root: root, totalSamples: root.count)
        return HangReport(
            hung: verdict != .responsive,
            kind: verdict,
            mainGapMS: offLoop,
            gapAtLeast: waiting == 0 && root.count > 0,
            busyMS: busyMS,
            blockedMS: blockedMS,
            eventWaitMS: waitMS,
            windowMS: root.count * interval,
            thresholdMS: thresholdMS,
            samples: root.count,
            top: stack.last.map(leafLabel) ?? "",
            stack: stack,
            hotspots: hotspots.isEmpty ? nil : hotspots
        )
    }

    private static let service = [
        "__CFRunLoopServiceMachPort",
        "_CFRunLoopServiceMachPort",
        "ReceiveNextEventCommon",
        "_BlockUntilNextEventMatchingListInMode",
        "_DPSBlockUntilNextEventMatchingListInMode",
        "GSEventRunModal",
    ]
    private static let calledOut = [
        "__CFRUNLOOP_IS_CALLING_OUT",
        "__CFRunLoopDoSources",
        "__CFRunLoopDoBlocks",
        "__CFRunLoopDoObservers",
        "__CFRunLoopDoTimers",
    ]
    private static let waits: Set<String> = [
        "mach_msg_trap", "mach_msg2_trap", "semaphore_wait_trap", "kevent", "kevent64",
        "__psynch_cvwait", "__psynch_mutexwait", "__semwait_signal", "ulock_wait",
        "nanosleep", "__select", "poll",
    ]
    private static let tree = Set<Character>(" \t+|!:")

    private static func interval(in text: String) throws -> Int {
        let pattern = #"every (\d+) milliseconds"#
        guard let match = text.range(of: pattern, options: .regularExpression) else {
            throw ProbeError("sample report has no interval.")
        }
        let line = String(text[match])
        guard let digits = line.split(separator: " ").dropFirst().first, let value = Int(digits) else {
            throw ProbeError("sample report has no interval.")
        }
        return value
    }

    private final class Node {
        let depth: Int
        let count: Int
        let symbol: String
        var children: [Node] = []
        init(depth: Int, count: Int, symbol: String) {
            self.depth = depth
            self.count = count
            self.symbol = symbol
        }
    }

    private static func mainThread(in text: String) throws -> Node {
        guard let start = text.range(of: "Call graph:") else {
            throw ProbeError("sample report has no call graph.")
        }
        let tail = text[start.lowerBound...]
        let end = tail.range(of: "Total number in stack").map { tail.distance(from: tail.startIndex, to: $0.lowerBound) }
        let graph = end.map { String(tail.prefix($0)) } ?? String(tail)
        var roots: [Node] = []
        var stack: [Node] = []
        for line in graph.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let parsed = parseLine(String(line)) else { continue }
            let node = Node(depth: parsed.0, count: parsed.1, symbol: parsed.2)
            while let last = stack.last, last.depth >= node.depth { stack.removeLast() }
            if let parent = stack.last {
                parent.children.append(node)
            } else {
                roots.append(node)
            }
            stack.append(node)
        }
        guard let main = roots.first(where: { $0.symbol.contains("com.apple.main-thread") }) else {
            throw ProbeError("sample report has no main thread.")
        }
        return main
    }

    private static func parseLine(_ line: String) -> (Int, Int, String)? {
        let chars = Array(line)
        var index = 0
        while index < chars.count, tree.contains(chars[index]) { index += 1 }
        let start = index
        while index < chars.count, chars[index].isNumber { index += 1 }
        if index == start { return nil }
        if index < chars.count, chars[index] != " ", chars[index] != "\t" { return nil }
        guard let count = Int(String(chars[start..<index])) else { return nil }
        let symbol = String(chars[index...]).trimmingCharacters(in: .whitespaces)
        return (start, count, symbol)
    }

    private static func leaves(_ node: Node, ancestors: [String]) -> [(Int, [String])] {
        let chain = ancestors + [node.symbol]
        if node.children.isEmpty { return [(node.count, chain)] }
        let childTotal = node.children.reduce(0) { $0 + $1.count }
        var result: [(Int, [String])] = []
        if node.count > childTotal { result.append((node.count - childTotal, chain)) }
        for child in node.children { result.append(contentsOf: leaves(child, ancestors: chain)) }
        return result
    }

    private static func kind(of chain: [String]) -> String {
        let leaf = leafLabel(chain[chain.count - 1])
        if waits.contains(leaf), inRunLoopWait(chain) { return "event" }
        if waits.contains(leaf) { return "blocked" }
        return "busy"
    }

    private static func inRunLoopWait(_ chain: [String]) -> Bool {
        for symbol in chain.reversed() {
            if calledOut.contains(where: { symbol.contains($0) }) { return false }
            if service.contains(where: { symbol.contains($0) }) { return true }
        }
        return false
    }

    private static func heaviest(_ tagged: [(String, Int, [String])], kind: String?) -> (String, Int, [String])? {
        var best: (String, Int, [String])?
        for item in tagged {
            if let kind, item.0 != kind { continue }
            if best == nil || item.1 > best!.1 { best = item }
        }
        return best
    }

    private static func displayStack(_ chain: [String]) -> [String] {
        var frames: [String] = []
        for symbol in chain {
            let short = shorten(symbol)
            let label = leafLabel(short)
            if label == "start" || label == "???" || label.hasPrefix("Thread_") { continue }
            frames.append(short)
        }
        if frames.isEmpty, let last = chain.last { frames = [shorten(last)] }
        return Array(frames.suffix(16))
    }

    static func leafLabel(_ symbol: String) -> String {
        let short = shorten(symbol)
        return short.components(separatedBy: " (in ").first?.trimmingCharacters(in: .whitespaces) ?? short
    }

    private static func extractHotspots(root: Node, totalSamples: Int) -> [FrameHotspot] {
        guard totalSamples > 0 else { return [] }
        var counts: [String: Int] = [:]
        func walk(_ node: Node) {
            let short = shorten(node.symbol)
            let label = leafLabel(short)
            if label != "start" && label != "???" && !label.hasPrefix("Thread_") {
                counts[short, default: 0] += node.count
            }
            for child in node.children {
                walk(child)
            }
        }
        for child in root.children {
            walk(child)
        }
        return counts
            .map { FrameHotspot(frame: $0.key, hits: min($0.value, totalSamples), totalSamples: totalSamples) }
            .sorted { lhs, rhs in
                if lhs.hits != rhs.hits { return lhs.hits > rhs.hits }
                return lhs.frame < rhs.frame
            }
            .prefix(10)
            .map { $0 }
    }

    private static func shorten(_ symbol: String) -> String {
        var text = symbol
        if let range = text.range(of: #"\s+\+\s+[0-9].*$"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        text = text.trimmingCharacters(in: .whitespaces)
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        return text
    }
}
