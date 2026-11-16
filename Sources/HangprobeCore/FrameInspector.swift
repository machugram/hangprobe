import Foundation

public enum FrameLayer: String, Codable, Equatable, Sendable {
    case app = "APP"
    case lock = "LOCK"
    case ui = "UI"
    case runloop = "LOOP"
    case system = "SYS"
    case kernel = "KERN"
}

public struct ClassifiedFrame: Equatable, Sendable, Identifiable {
    public var index: Int
    public var raw: String
    public var symbol: String
    public var module: String?
    public var layer: FrameLayer
    public var hint: String?

    public var id: Int { index }

    public var isDeveloperFocus: Bool {
        layer == .app || layer == .lock
    }

    public init(index: Int, raw: String, symbol: String, module: String?, layer: FrameLayer, hint: String?) {
        self.index = index
        self.raw = raw
        self.symbol = symbol
        self.module = module
        self.layer = layer
        self.hint = hint
    }
}

public enum FrameGroup: Equatable, Sendable, Identifiable {
    case focus(ClassifiedFrame)
    case collapsedSystem(id: Int, frames: [ClassifiedFrame])

    public var id: String {
        switch self {
        case .focus(let frame): return "f-\(frame.index)"
        case .collapsedSystem(let id, _): return "s-\(id)"
        }
    }
}

public enum FrameInspector {
    public static func inspect(stack: [String], app: String?, bundleID: String? = nil) -> [ClassifiedFrame] {
        stack.enumerated().map { idx, raw in
            classify(index: idx, raw: raw, app: app, bundleID: bundleID)
        }
    }

    public static func grouped(stack: [String], app: String?, bundleID: String? = nil) -> [FrameGroup] {
        let items = inspect(stack: stack, app: app, bundleID: bundleID)
        guard !items.isEmpty else { return [] }
        var out: [FrameGroup] = []
        var buffer: [ClassifiedFrame] = []

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            if buffer.count == 1 {
                out.append(.focus(buffer[0]))
            } else {
                out.append(.collapsedSystem(id: buffer[0].index, frames: buffer))
            }
            buffer.removeAll()
        }

        for (offset, frame) in items.enumerated() {
            let isLeaf = offset == items.count - 1
            if frame.isDeveloperFocus || isLeaf {
                flushBuffer()
                out.append(.focus(frame))
            } else {
                buffer.append(frame)
            }
        }
        flushBuffer()
        return out
    }

    public static func contentionSummary(for report: HangReport) -> String? {
        let inspected = inspect(stack: report.stack, app: report.app, bundleID: report.bundleID)
        if let lockFrame = inspected.reversed().first(where: { $0.layer == .lock }), let hint = lockFrame.hint {
            return hint
        }
        if report.kind == .busy {
            if let appFrame = inspected.reversed().first(where: { $0.layer == .app }) {
                return "Main thread stayed on-CPU inside \(appFrame.symbol)."
            }
            return "Main thread stayed on-CPU outside the event loop."
        }
        return nil
    }

    private static func classify(index: Int, raw: String, app: String?, bundleID: String?) -> ClassifiedFrame {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let (symbol, module) = splitSymbolAndModule(trimmed)
        let lowerRaw = trimmed.lowercased()
        let lowerSym = symbol.lowercased()
        let lowerMod = (module ?? "").lowercased()

        if trimmed.hasPrefix("- waiting to lock") || trimmed.hasPrefix("- waiting on") {
            return ClassifiedFrame(
                index: index,
                raw: trimmed,
                symbol: trimmed,
                module: "ART Monitor",
                layer: .lock,
                hint: "Java/Kotlin monitor contention (\(trimmed))."
            )
        }

        if lowerSym.contains("psynch_mutexwait") || lowerSym.contains("pthread_mutex_lock") || lowerSym.contains("_pthread_mutex_firstfit") {
            return ClassifiedFrame(
                index: index,
                raw: trimmed,
                symbol: symbol,
                module: module,
                layer: .lock,
                hint: "Blocked acquiring a POSIX / NSLock mutex on the main thread."
            )
        }

        if lowerSym.contains("dispatch_sync") || lowerSym.contains("sema4_wait") || lowerSym.contains("semaphore_wait") || lowerSym.contains("ulock_wait") {
            return ClassifiedFrame(
                index: index,
                raw: trimmed,
                symbol: symbol,
                module: module,
                layer: .lock,
                hint: "Blocked on synchronous dispatch queue / semaphore wait."
            )
        }

        if lowerSym.contains("semwait_signal") || lowerSym.contains("nanosleep") || lowerSym.contains("thread.sleep") {
            return ClassifiedFrame(
                index: index,
                raw: trimmed,
                symbol: symbol,
                module: module,
                layer: .lock,
                hint: "Main thread parked in an explicit sleep timer."
            )
        }

        if lowerSym.contains("futex") {
            return ClassifiedFrame(
                index: index,
                raw: trimmed,
                symbol: symbol,
                module: module,
                layer: .lock,
                hint: "Android native futex / lock wait off Looper."
            )
        }

        if isAppOwned(raw: trimmed, symbol: symbol, module: module, app: app, bundleID: bundleID) {
            return ClassifiedFrame(index: index, raw: trimmed, symbol: symbol, module: module, layer: .app, hint: nil)
        }

        if lowerMod.contains("kernel") || lowerMod.contains("libc.so") || lowerSym.hasPrefix("mach_msg") || lowerSym.contains("epoll_wait") || lowerSym.contains("kevent") {
            return ClassifiedFrame(index: index, raw: trimmed, symbol: symbol, module: module, layer: .kernel, hint: nil)
        }

        if lowerRaw.contains("cfrunloop") || lowerRaw.contains("nsrunloop") || lowerRaw.contains("looper.loop") || lowerRaw.contains("messagequeue") || lowerRaw.contains("receivenexteventcommon") {
            return ClassifiedFrame(index: index, raw: trimmed, symbol: symbol, module: module, layer: .runloop, hint: nil)
        }

        if lowerMod.contains("swiftui") || lowerMod.contains("uikit") || lowerMod.contains("appkit") || lowerMod.contains("quartzcore") || lowerRaw.contains("android.view.") || lowerRaw.contains("androidx.compose") {
            return ClassifiedFrame(index: index, raw: trimmed, symbol: symbol, module: module, layer: .ui, hint: nil)
        }

        return ClassifiedFrame(index: index, raw: trimmed, symbol: symbol, module: module, layer: .system, hint: nil)
    }

    private static func isAppOwned(raw: String, symbol: String, module: String?, app: String?, bundleID: String?) -> Bool {
        if let app, !app.isEmpty {
            if module == app { return true }
            if raw.contains("(in \(app))") || raw.contains("at \(app).") || symbol.hasPrefix("\(app).") {
                return true
            }
        }
        if let bundleID, !bundleID.isEmpty {
            if raw.contains(bundleID) || symbol.hasPrefix(bundleID) {
                return true
            }
        }
        // Unrecognized Java/Kotlin package that is not android/java/kotlin/dalvik/com.android
        if raw.hasPrefix("at ") {
            let clean = String(raw.dropFirst(3))
            let systemPrefixes = ["android.", "androidx.", "com.android.", "java.", "javax.", "kotlin.", "kotlinx.", "dalvik.", "sun."]
            if !systemPrefixes.contains(where: { clean.hasPrefix($0) }) {
                return true
            }
        }
        return false
    }

    private static func splitSymbolAndModule(_ raw: String) -> (String, String?) {
        if let range = raw.range(of: " (in ", options: .backwards), raw.hasSuffix(")") {
            let sym = String(raw[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let modStart = range.upperBound
            let modEnd = raw.index(before: raw.endIndex)
            let mod = String(raw[modStart..<modEnd])
            return (sym, mod)
        }
        if raw.hasPrefix("at ") {
            let body = String(raw.dropFirst(3))
            if let paren = body.firstIndex(of: "(") {
                let sym = String(body[..<paren])
                let loc = String(body[body.index(after: paren)...].dropLast(body.hasSuffix(")") ? 1 : 0))
                return (sym, loc)
            }
            return (body, nil)
        }
        if raw.contains(" pc "), let open = raw.lastIndex(of: "("), let close = raw.lastIndex(of: ")"), open < close {
            let inside = String(raw[raw.index(after: open)..<close])
            let before = raw[..<open].split(separator: " ").last.map(String.init)
            return (inside, before)
        }
        return (raw, nil)
    }
}
