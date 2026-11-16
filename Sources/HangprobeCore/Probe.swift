import Foundation

public enum ProbeLimits {
    public static func seconds(_ value: Int) throws -> Int {
        guard (1...3).contains(value) else { throw ProbeError("seconds must be 1, 2, or 3.") }
        return value
    }

    public static func threshold(_ value: Int) throws -> Int {
        guard (50...3000).contains(value) else { throw ProbeError("threshold_ms must be between 50 and 3000.") }
        return value
    }
}

public enum Probe {
    public static func hang(app: String?, seconds: Int = 1, thresholdMS: Int = 250) throws -> HangReport {
        let seconds = try ProbeLimits.seconds(seconds)
        let thresholdMS = try ProbeLimits.threshold(thresholdMS)
        return try sample(app: app, seconds: seconds, thresholdMS: thresholdMS)
    }

    public static func worst(app: String?, thresholdMS: Int = 250) throws -> HangReport {
        let thresholdMS = try ProbeLimits.threshold(thresholdMS)
        return try sample(app: app, seconds: 10, thresholdMS: thresholdMS)
    }

    public static func watch(
        app: String?,
        seconds: Int = 1,
        thresholdMS: Int = 250,
        attempts: Int = 8,
        pause: () -> Void = {},
        onAttempt: ((Int) -> Void)? = nil
    ) throws -> HangReport {
        let seconds = try ProbeLimits.seconds(seconds)
        let thresholdMS = try ProbeLimits.threshold(thresholdMS)
        var started = false
        var attempt = 0
        return try WatchRun.firstHang(attempts: attempts) {
            if started { pause() }
            started = true
            attempt += 1
            onAttempt?(attempt)
            return try sample(app: app, seconds: seconds, thresholdMS: thresholdMS)
        }
    }

    private static func sample(app: String?, seconds: Int, thresholdMS: Int) throws -> HangReport {
        let target = try resolve(app)
        if target.place == .android {
            guard let serial = target.serial else { throw ProbeError("Android target \(target.app) has no adb device.") }
            var report = try AndroidDevices.probe(
                serial: serial,
                package: target.bundleID ?? target.app,
                pid: target.pid,
                seconds: seconds,
                thresholdMS: thresholdMS
            )
            report.stack = Symbolicator.symbolicate(stack: report.stack, pid: nil, app: report.app ?? "")
            report.context = mergeContext(report.context, for: target, stack: report.stack)
            return report
        }
        let text = try Sampler.sample(pid: target.pid, seconds: seconds)
        var report = try SampleClassifier.classify(text, thresholdMS: thresholdMS)
        report.pid = Int(target.pid)
        report.app = target.app
        report.bundleID = target.bundleID
        report.place = target.place
        report.stack = Symbolicator.symbolicate(stack: report.stack, pid: target.pid, app: target.app)
        if let top = report.stack.last { report.top = SampleClassifier.leafLabel(top) }
        report.context = mergeContext(report.context, for: target, stack: report.stack)
        return report
    }

    private static func mergeContext(_ existing: HangContext?, for target: RunningApp, stack: [String]) -> HangContext {
        var ctx = existing ?? HangContext()
        if ctx.capturedAt == nil {
            ctx.capturedAt = ISO8601DateFormatter().string(from: Date())
        }
        if ctx.arch == nil {
            #if arch(arm64)
            ctx.arch = "arm64"
            #elseif arch(x86_64)
            ctx.arch = "x86_64"
            #endif
        }
        if ctx.os == nil {
            let v = ProcessInfo.processInfo.operatingSystemVersion
            let prefix = target.place == .simulator ? "Simulator host macOS" : "macOS"
            ctx.os = "\(prefix) \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        }
        if ctx.device == nil {
            switch target.place {
            case .android:
                ctx.device = target.serial.map { "adb \($0)" } ?? "Android"
            case .simulator:
                ctx.device = "iOS Simulator"
            case .mac, .ios:
                ctx.device = Host.current().localizedName ?? "Mac"
            }
        }
        if ctx.screen == nil, let appFrame = Symbolicator.leadingAppFrame(stack: stack, app: target.app) {
            ctx.screen = SampleClassifier.leafLabel(appFrame)
        }
        if ctx.commit == nil {
            ctx.commit = gitShortHEAD()
        }
        return ctx
    }

    private static func gitShortHEAD() -> String? {
        guard let result = try? Shell.run(
            ["/usr/bin/git", "rev-parse", "--short", "HEAD"],
            timeout: 2
        ), result.status == 0 else { return nil }
        let hash = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return hash.isEmpty ? nil : hash
    }

    public static func resolve(_ app: String?) throws -> RunningApp {
        let trimmed = app?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed == "booted" || trimmed == "simulator" {
            return try onlySimulatorApp()
        }
        if trimmed.unicodeScalars.contains(where: { $0.value < 32 }) {
            throw ProbeError("app must be a pid, bundle id, or process name.")
        }
        if trimmed.allSatisfy(\.isNumber) {
            guard let pid = Int32(trimmed) else { throw ProbeError("No process has pid \(trimmed).") }
            return try target(pid: pid, bundleID: nil)
        }
        if isBundle(trimmed) {
            if let android = androidTarget(matching: trimmed) { return android }
            return try resolveBundle(trimmed)
        }
        if !isName(trimmed) { throw ProbeError("app must be a pid, bundle id, or process name.") }
        do { return try resolveName(trimmed) }
        catch let error as ProbeError where error.message.hasPrefix("No running process is named") {
            if let android = androidTarget(matching: trimmed) { return android }
            throw error
        }
    }

    private static func onlySimulatorApp() throws -> RunningApp {
        let hits = ProcessList.processes().compactMap { pid, command -> (Int32, String)? in
            let executable = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
            guard executable.contains("CoreSimulator/Devices/"), executable.contains(".app/"), !executable.contains(".appex/") else { return nil }
            return (pid, executable)
        }
        if hits.isEmpty {
            throw ProbeError("No user app is running in the Simulator. Pass app as a bundle id, name, or pid.")
        }
        if hits.count > 1 {
            let listed = hits.map { "\($0.0) (\(URL(fileURLWithPath: $0.1).lastPathComponent))" }.joined(separator: ", ")
            throw ProbeError("More than one Simulator app is running: \(listed). Pass app.")
        }
        let hit = hits[0]
        return RunningApp(pid: hit.0, app: URL(fileURLWithPath: hit.1).lastPathComponent, place: .simulator)
    }

    private static func resolveName(_ name: String) throws -> RunningApp {
        let hits = ProcessList.processes().compactMap { pid, command -> (Int32, String)? in
            let executable = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
            guard URL(fileURLWithPath: executable).lastPathComponent == name else { return nil }
            return (pid, executable)
        }
        if hits.isEmpty { throw ProbeError("No running process is named \(name).") }
        if hits.count > 1 {
            throw ProbeError("\(name) has more than one process: \(hits.map { String($0.0) }.joined(separator: ", ")). Pass a pid.")
        }
        return RunningApp(pid: hits[0].0, app: name, place: place(of: hits[0].1))
    }

    private static func resolveBundle(_ bundleID: String) throws -> RunningApp {
        if let info = simAppInfo(bundleID) {
            let binary = info.path.replacingOccurrences(of: "/$", with: "", options: .regularExpression) + "/" + info.executable
            let hits = ProcessList.processes().compactMap { pid, command -> Int32? in
                let executable = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
                return executable == binary ? pid : nil
            }
            if hits.isEmpty {
                throw ProbeError("\(info.name) (\(bundleID)) is installed on the booted Simulator but not running.")
            }
            if hits.count > 1 { throw ProbeError("\(bundleID) has more than one process. Pass a pid.") }
            return RunningApp(pid: hits[0], app: info.name, bundleID: bundleID, place: .simulator)
        }
        guard let pid = macPID(bundleID) else { throw ProbeError("No running app has bundle id \(bundleID).") }
        return try target(pid: pid, bundleID: bundleID)
    }

    private static func target(pid: Int32, bundleID: String?) throws -> RunningApp {
        for (found, command) in ProcessList.processes() where found == pid {
            let executable = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
            return RunningApp(
                pid: pid,
                app: URL(fileURLWithPath: executable).lastPathComponent,
                bundleID: bundleID,
                place: place(of: executable)
            )
        }
        throw ProbeError("No process has pid \(pid).")
    }

    private static func androidTarget(matching name: String) -> RunningApp? {
        let hits = AndroidDevices.running().filter { $0.app == name || $0.bundleID == name }
        return hits.count == 1 ? hits[0] : nil
    }

    private static func place(of executable: String) -> ProbePlace {
        executable.contains("CoreSimulator/Devices/") ? .simulator : .mac
    }

    private static func isBundle(_ text: String) -> Bool {
        text.contains(".") && text.range(of: #"^[A-Za-z0-9][A-Za-z0-9.\-]{1,220}$"#, options: .regularExpression) != nil
    }

    private static func isName(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9][A-Za-z0-9 ._\-]{0,80}$"#, options: .regularExpression) != nil
    }

    private struct SimInfo {
        var path: String
        var executable: String
        var name: String
    }

    private static func simAppInfo(_ bundleID: String) -> SimInfo? {
        guard let listed = try? Shell.run(["/usr/bin/xcrun", "simctl", "appinfo", "booted", bundleID], timeout: 20),
              listed.status == 0 else { return nil }
        guard let converted = try? Shell.run(
            ["/usr/bin/plutil", "-convert", "json", "-o", "-", "-"],
            timeout: 20,
            input: Data(listed.stdout.utf8)
        ), converted.status == 0,
              let data = converted.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var object = json as? [String: Any]
        if let nested = object?[bundleID] as? [String: Any] { object = nested }
        guard var path = object?["Path"] as? String, let executable = object?["CFBundleExecutable"] as? String, !path.isEmpty, !executable.isEmpty else {
            return nil
        }
        if path.hasPrefix("file://") { path = String(path.dropFirst(7)) }
        let name = (object?["CFBundleDisplayName"] as? String) ?? (object?["CFBundleName"] as? String) ?? executable
        return SimInfo(path: path, executable: executable, name: name)
    }

    private static func macPID(_ bundleID: String) -> Int32? {
        let escaped = bundleID.replacingOccurrences(of: "\"", with: "")
        let script = "tell application \"System Events\" to unix id of first process whose bundle identifier is \"\(escaped)\""
        guard let result = try? Shell.run(["/usr/bin/osascript", "-e", script], timeout: 15), result.status == 0 else { return nil }
        return Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
