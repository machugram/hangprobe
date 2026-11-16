import Foundation

public enum AndroidTrace {
    public static let anrNote = "ANR. Android's input timeout is about 5 seconds, not 250 ms."
    public static let liveNote = "Live main-thread dump. A stall here is at least the threshold; this is not a timed sample."
    public static let parkedNote = "Live main-thread dump. The main thread is parked in Looper."

    public static func isANR(_ text: String) -> Bool {
        text.contains("ANR in ")
            || text.contains("Input dispatching timed out")
            || text.contains("am_anr")
            || text.contains("Reason: Input dispatching timed out")
    }

    public static func classify(_ text: String, thresholdMS: Int, package: String? = nil) throws -> HangReport {
        let section = try mainSection(in: text)
        let frames = frames(in: section.body)
        if frames.isEmpty { throw ProbeError("Android trace has no main-thread frames.") }
        let leafLast = Array(frames.reversed())
        let leaf = leafLast.last ?? frames[0]
        let kind = kind(of: section.header + "\n" + section.body, leaf: leaf, frames: leafLast)
        let anr = isANR(text)
        let stalled = kind != .responsive
        let gap = anr && stalled ? 5000 : (stalled ? thresholdMS : 0)
        let note = anr ? anrNote : (stalled ? liveNote : parkedNote)
        let stack = Array(leafLast.suffix(16))
        let hotspots = stack.reversed().prefix(8).map { FrameHotspot(frame: $0, hits: 1, totalSamples: 1) }
        return HangReport(
            hung: stalled,
            kind: kind,
            mainGapMS: gap,
            gapAtLeast: stalled,
            busyMS: kind == .busy ? gap : 0,
            blockedMS: kind == .blocked ? gap : 0,
            eventWaitMS: kind == .responsive ? 250 : 0,
            windowMS: max(gap, kind == .responsive ? 250 : 0),
            thresholdMS: thresholdMS,
            samples: 1,
            top: leafLabel(leaf),
            stack: stack,
            app: package,
            bundleID: package,
            place: .android,
            note: note,
            hotspots: hotspots
        )
    }

    /// Aggregates a multi-sample Embrace-style burst of main-thread dumps over `windowMS` into a timed HangReport.
    public static func classifyBurst(
        _ dumps: [String],
        windowMS: Int,
        thresholdMS: Int,
        package: String? = nil
    ) throws -> HangReport {
        let parsed = dumps.compactMap { dump -> HangReport? in
            let trimmed = dump.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return try? classify(trimmed, thresholdMS: thresholdMS, package: package)
        }
        guard !parsed.isEmpty else {
            throw ProbeError("Android burst produced no readable main-thread dumps.")
        }
        if parsed.count == 1 {
            return parsed[0]
        }

        let total = parsed.count
        let sliceMS = max(1, windowMS / total)
        var busyCount = 0
        var blockedCount = 0
        var waitCount = 0
        var frameHits: [String: Int] = [:]
        var stackVotes: [HangKind: [([String], Int)]] = [:]

        for item in parsed {
            switch item.kind {
            case .busy: busyCount += 1
            case .blocked: blockedCount += 1
            case .responsive: waitCount += 1
            }
            for uniqueFrame in Set(item.stack) {
                frameHits[uniqueFrame, default: 0] += 1
            }
            var list = stackVotes[item.kind, default: []]
            if let idx = list.firstIndex(where: { $0.0.last == item.stack.last }) {
                list[idx].1 += 1
            } else {
                list.append((item.stack, 1))
            }
            stackVotes[item.kind] = list
        }

        let busyMS = busyCount * sliceMS
        let blockedMS = blockedCount * sliceMS
        let waitMS = waitCount * sliceMS
        let offLoopMS = busyMS + blockedMS
        let verdict: HangKind
        if offLoopMS >= thresholdMS && blockedMS >= busyMS {
            verdict = .blocked
        } else if offLoopMS >= thresholdMS {
            verdict = .busy
        } else {
            verdict = .responsive
        }

        let chosenStack = stackVotes[verdict]?.max(by: { $0.1 < $1.1 })?.0
            ?? parsed.last?.stack
            ?? []
        let hotspots = frameHits
            .map { FrameHotspot(frame: $0.key, hits: $0.value, totalSamples: total) }
            .sorted { lhs, rhs in
                if lhs.hits != rhs.hits { return lhs.hits > rhs.hits }
                return lhs.frame < rhs.frame
            }
            .prefix(10)
            .map { $0 }

        let anyANR = dumps.contains(where: isANR)
        let finalGap = anyANR && verdict != .responsive ? max(5000, offLoopMS) : offLoopMS
        let note = anyANR
            ? anrNote
            : "Sampled \(total) live Looper dumps across \(total * sliceMS) ms over adb."

        return HangReport(
            hung: verdict != .responsive,
            kind: verdict,
            mainGapMS: finalGap,
            gapAtLeast: waitCount == 0,
            busyMS: busyMS,
            blockedMS: blockedMS,
            eventWaitMS: waitMS,
            windowMS: max(finalGap, total * sliceMS),
            thresholdMS: thresholdMS,
            samples: total,
            top: chosenStack.last.map(leafLabel) ?? "",
            stack: chosenStack,
            app: package,
            bundleID: package,
            place: .android,
            note: note,
            hotspots: hotspots
        )
    }

    private struct Section {
        var header: String
        var body: String
    }

    private static func mainSection(in text: String) throws -> Section {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("\"main\"") || $0.contains("name: main") }) else {
            throw ProbeError("Android trace has no main thread.")
        }
        var end = lines.count
        if start + 1 < lines.count {
            for index in (start + 1)..<lines.count {
                let line = lines[index]
                if line.hasPrefix("\"") || line.hasPrefix("----- end") || line.hasPrefix("----- pid") {
                    end = index
                    break
                }
            }
        }
        return Section(header: lines[start], body: lines[(start + 1)..<end].joined(separator: "\n"))
    }

    private static func frames(in body: String) -> [String] {
        body.split(separator: "\n").map(String.init).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("at ") || trimmed.hasPrefix("native:") || trimmed.hasPrefix("- waiting") || trimmed.contains(" pc ")
        }.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func kind(of text: String, leaf: String, frames: [String]) -> HangKind {
        if isEventLoop(leaf: leaf, frames: frames) { return .responsive }
        if text.contains("waiting to lock") || text.contains("waiting on <") || text.range(of: #"tid=\d+ Blocked"#, options: .regularExpression) != nil {
            return .blocked
        }
        let label = leafLabel(leaf)
        let locks = ["futex", "__futex", "syscall", "pthread_mutex_lock", "pthread_cond_wait", "monitor contention"]
        if locks.contains(where: { label.contains($0) || leaf.contains($0) }) { return .blocked }
        return .busy
    }

    private static func isEventLoop(leaf: String, frames: [String]) -> Bool {
        let waits = ["nativePollOnce", "epoll_wait", "epoll_pwait", "android_os_MessageQueue_nativePollOnce", "MessageQueue.next"]
        let loop = frames.contains {
            $0.contains("android.os.Looper.loop")
                || $0.contains("android.os.MessageQueue")
                || $0.contains("MessageQueue_nativePollOnce")
                || $0.contains("android_os_MessageQueue")
        }
        return loop && waits.contains(where: { leaf.contains($0) })
    }

    static func leafLabel(_ frame: String) -> String {
        var text = frame.trimmingCharacters(in: .whitespaces)
        if text.contains(" pc "), let open = text.lastIndex(of: "("), let close = text.lastIndex(of: ")"), open < close {
            let inside = text[text.index(after: open)..<close]
            return inside.split(separator: "+").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? String(inside)
        }
        if text.hasPrefix("at ") { text = String(text.dropFirst(3)) }
        if text.hasPrefix("native:") { text = text.replacingOccurrences(of: "native:", with: "").trimmingCharacters(in: .whitespaces) }
        if let paren = text.firstIndex(of: "(") { text = String(text[..<paren]) }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

/// Parses Android 11+ `adb shell dumpsys activity exit-info [package]` records (REASON_ANR = 6)
/// — the same ground-truth source used by Firebase Crashlytics and Google Play Android Vitals.
public enum AndroidExitInfoParser {
    public static func parse(_ dumpsysText: String, thresholdMS: Int = 250) -> [HangReport] {
        let blocks = dumpsysText.components(separatedBy: "ApplicationExitInfo #")
        var reports: [HangReport] = []

        for rawBlock in blocks.dropFirst() {
            guard rawBlock.contains("reason=6 (ANR)") || rawBlock.contains("reason=ANR") || rawBlock.contains("(ANR)") else {
                continue
            }
            let pid = captureInt(rawBlock, #"pid=(\d+)"#)
            let processName = capture(rawBlock, #"process=([^\s\n]+)"#) ?? "android.app"
            let timestamp = capture(rawBlock, #"timestamp=([^\n]+)"#)?.trimmingCharacters(in: .whitespaces)
            let description = capture(rawBlock, #"description=([^\n]+)"#)?.trimmingCharacters(in: .whitespaces)
            let pss = capture(rawBlock, #"pss=([^\s\n]+)"#)

            let detail = description ?? "Input dispatching timed out"
            let syntheticFrame = "at \(processName).MainThread(<ApplicationExitInfo REASON_ANR>)"
            let reasonFrame = "- \(detail)"
            let stack = [syntheticFrame, reasonFrame]

            let context = HangContext(
                commit: nil,
                screen: detail,
                device: "Android (adb exit-info)",
                os: "Android 11+ (API 30+)",
                arch: nil,
                loadAddress: pss.map { "pss:\($0)" },
                capturedAt: timestamp
            )

            reports.append(HangReport(
                hung: true,
                kind: .blocked,
                mainGapMS: 5000,
                gapAtLeast: true,
                busyMS: 0,
                blockedMS: 5000,
                eventWaitMS: 0,
                windowMS: 5000,
                thresholdMS: thresholdMS,
                samples: 1,
                top: detail,
                stack: stack,
                pid: pid,
                app: processName,
                bundleID: processName,
                place: .android,
                note: "\(AndroidTrace.anrNote) Historical Play Vitals / ApplicationExitInfo record (\(detail)).",
                context: context,
                hotspots: [FrameHotspot(frame: syntheticFrame, hits: 1, totalSamples: 1)]
            ))
        }
        return reports
    }

    private static func capture(_ text: String, _ pattern: String) -> String? {
        ProcessList.capture(text, pattern)
    }

    private static func captureInt(_ text: String, _ pattern: String) -> Int? {
        capture(text, pattern).flatMap(Int.init)
    }
}

public enum AndroidDevices {
    public static func running() -> [RunningApp] {
        guard adbAvailable() else { return [] }
        let listed: String
        do { listed = try Shell.run(["/usr/bin/env", "adb", "devices", "-l"], timeout: 8).stdout }
        catch { return [] }
        var apps: [RunningApp] = []
        for serial in serials(in: listed) {
            apps.append(contentsOf: packages(on: serial))
        }
        return apps
    }

    public static func serials(in text: String) -> [String] {
        text.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count >= 2, parts[1] == "device" else { return nil }
            return parts[0]
        }
    }

    public static func runningPackages(packages: [String], processList: String) -> [(pid: Int32, package: String)] {
        let wanted = Set(packages)
        var found: [(Int32, String)] = []
        for line in processList.split(separator: "\n") {
            let parts = line.split(separator: " ").map(String.init)
            guard let name = parts.last, wanted.contains(name) else { continue }
            guard let pid = parts.compactMap({ Int32($0) }).first else { continue }
            found.append((pid, name))
        }
        return found
    }

    public static func probe(
        serial: String,
        package: String,
        pid: Int32,
        seconds: Int = 1,
        thresholdMS: Int
    ) throws -> HangReport {
        let symbols = ProcessInfo.processInfo.environment["HANGPROBE_NDK_SYMBOLS"]
        let burstCount = min(max(seconds * 4, 3), 10)
        let intervalSeconds = Double(max(1, seconds)) / Double(burstCount)
        var dumps: [String] = []

        for sampleIndex in 0..<burstCount {
            let start = Date()
            let live = (try? Shell.run(
                ["/usr/bin/env", "adb", "-s", serial, "shell", "debuggerd", "-b", String(pid)],
                timeout: 6
            ).stdout) ?? ""
            if live.contains("\"main\"") || live.contains("name: main") {
                dumps.append(Symbolicator.ndkStack(trace: live, symbolPath: symbols))
            } else if sampleIndex == 0 {
                break
            }
            if sampleIndex + 1 < burstCount {
                let elapsed = Date().timeIntervalSince(start)
                if elapsed < intervalSeconds {
                    Thread.sleep(forTimeInterval: intervalSeconds - elapsed)
                }
            }
        }

        var report: HangReport
        if !dumps.isEmpty {
            report = try AndroidTrace.classifyBurst(
                dumps,
                windowMS: max(1, seconds) * 1000,
                thresholdMS: thresholdMS,
                package: package
            )
        } else {
            _ = try? Shell.run(["/usr/bin/env", "adb", "-s", serial, "shell", "kill", "-3", String(pid)], timeout: 8)
            let fallback = (try? Shell.run(
                ["/usr/bin/env", "adb", "-s", serial, "shell", "cat", "/data/anr/traces.txt"],
                timeout: 8
            ).stdout) ?? ""
            if fallback.isEmpty { throw ProbeError("adb produced no main-thread trace for \(package).") }
            let traced = Symbolicator.ndkStack(trace: fallback, symbolPath: symbols)
            report = try AndroidTrace.classify(traced, thresholdMS: thresholdMS, package: package)
        }

        if let recent = recentANR(serial: serial, package: package), report.severity != .androidANR {
            report.note = AndroidTrace.anrNote + " " + recent
        }
        report.pid = Int(pid)
        report.app = package
        report.bundleID = package
        report.place = .android
        return report
    }

    public static func pullExitInfoANRs(package: String? = nil, thresholdMS: Int = 250) throws -> [HangReport] {
        guard adbAvailable() else {
            throw ProbeError("adb is not installed or not on PATH.")
        }
        let listed = try Shell.run(["/usr/bin/env", "adb", "devices", "-l"], timeout: 8).stdout
        let connected = serials(in: listed)
        guard let serial = connected.first else {
            throw ProbeError("adb sees no connected Android device or booted emulator.")
        }
        var cmd = ["/usr/bin/env", "adb", "-s", serial, "shell", "dumpsys", "activity", "exit-info"]
        if let package, !package.isEmpty {
            cmd.append(package)
        }
        let out = try Shell.run(cmd, timeout: 12).stdout
        return AndroidExitInfoParser.parse(out, thresholdMS: thresholdMS)
    }

    private static func packages(on serial: String) -> [RunningApp] {
        guard let listed = try? Shell.run(
            ["/usr/bin/env", "adb", "-s", serial, "shell", "pm", "list", "packages", "-3"],
            timeout: 8
        ).stdout else { return [] }
        let names = listed.split(separator: "\n").compactMap { line -> String? in
            let row = String(line).trimmingCharacters(in: .whitespaces)
            guard row.hasPrefix("package:") else { return nil }
            return String(row.dropFirst("package:".count))
        }
        guard let processes = try? Shell.run(
            ["/usr/bin/env", "adb", "-s", serial, "shell", "ps", "-A"],
            timeout: 8
        ).stdout else { return [] }
        return runningPackages(packages: names, processList: processes).map { hit in
            RunningApp(pid: hit.pid, app: hit.package, bundleID: hit.package, place: .android, serial: serial)
        }
    }

    private static func recentANR(serial: String, package: String) -> String? {
        guard let stamp = try? Shell.run(
            ["/usr/bin/env", "adb", "-s", serial, "shell", "stat", "-c", "%Y", "/data/anr/traces.txt"],
            timeout: 5
        ).stdout else { return nil }
        guard let modified = TimeInterval(stamp.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        if Date().timeIntervalSince1970 - modified > 30 { return nil }
        return "A traces file for \(package) was just written."
    }

    private static func adbAvailable() -> Bool {
        (try? Shell.run(["/usr/bin/env", "which", "adb"], timeout: 3).status) == 0
    }
}
