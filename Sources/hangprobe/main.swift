import Foundation
import HangprobeCore

private let help = """
hangprobe — see why a Mac, Simulator, Android, or debug iOS app stopped answering

  MIT open source — every command is free:

    hangprobe ui                       open the Mac studio window
    hangprobe probe [app]              live main-thread sample as JSON (exit 1 if hung)
    hangprobe mcp                      speak MCP (probe_hang) on stdin
    hangprobe watch [app]              sample repeatedly until the first hang
    hangprobe worst [app]              one 10 second sample
    hangprobe diff [app]               compare the last two saved probes
    hangprobe import <mxhang.json>     import MetricKit MXHangDiagnostic JSON
    hangprobe appexit [package]        pull Android 11+ ApplicationExitInfo ANRs over adb
    hangprobe inbox [--port 9481]      receive phone hangs (loopback default; --bind all · --token)
    hangprobe gate [app]               fail CI if hung or regressed past budget
    hangprobe version                  print MIT / version JSON
"""

@main
enum HangprobeCLI {
    static func main() {
        let argv = Array(CommandLine.arguments.dropFirst())
        if argv.isEmpty {
            if isatty(STDIN_FILENO) == 1 {
                fputs("The page has been retired. Opening the Hangprobe window.\n", stderr)
                let status = (try? AppLauncher.open()) ?? 2
                exit(status)
            }
            fputs(help, stdout)
            exit(0)
        }
        let command = argv[0]
        let rest = Array(argv.dropFirst())
        switch command {
        case "-h", "--help":
            fputs(help, stdout)
            exit(0)
        case "ui":
            do { exit(try AppLauncher.open()) } catch {
                fputs("\(error)\n", stderr)
                exit(2)
            }
        case "probe":
            exit(runProbe(rest))
        case "watch":
            exit(runWatch(rest))
        case "worst":
            exit(runWorst(rest))
        case "diff":
            exit(runDiff(rest))
        case "gate":
            exit(runGate(rest))
        case "import":
            exit(runImport(rest))
        case "appexit":
            exit(runAppExit(rest))
        case "inbox":
            exit(runInbox(rest))
        case "version", "license":
            exit(runVersion(rest))
        case "mcp":
            if !rest.isEmpty {
                fputs("mcp takes no arguments.\n", stderr)
                exit(2)
            }
            MCPSession.serve(probe: { app, seconds, threshold in
                return try Probe.hang(app: app, seconds: seconds, thresholdMS: threshold)
            })
            exit(0)
        default:
            fputs("Unknown command \(command).\n\(help)", stderr)
            exit(2)
        }
    }

    private static func runProbe(_ args: [String]) -> Int32 {
        do {
            let request = try Request.parse(args)
            let report = try Probe.hang(app: request.app, seconds: request.seconds, thresholdMS: request.threshold)
            try ProbeStore.shared.append(report)
            try printJSON(report)
            return ProbeExit.code(for: report)
        } catch {
            fputs("\(error)\n", stderr)
            return 2
        }
    }

    private static func runWatch(_ args: [String]) -> Int32 {
        do {
            let request = try Request.parse(args)
            let report = try Probe.watch(app: request.app, seconds: request.seconds, thresholdMS: request.threshold, pause: {
                Thread.sleep(forTimeInterval: 2)
            })
            try ProbeStore.shared.append(report)
            try printJSON(report)
            return ProbeExit.code(for: report)
        } catch {
            fputs("\(error)\n", stderr)
            return 2
        }
    }

    private static func runWorst(_ args: [String]) -> Int32 {
        do {
            let request = try Request.parse(args)
            let report = try Probe.worst(app: request.app, thresholdMS: request.threshold)
            try ProbeStore.shared.append(report)
            try printJSON(report)
            return ProbeExit.code(for: report)
        } catch {
            fputs("\(error)\n", stderr)
            return 2
        }
    }

    private static func runDiff(_ args: [String]) -> Int32 {
        do {
            let request = try Request.parse(args)
            guard let app = request.app else {
                throw ProbeError("diff needs the app name.")
            }
            guard let pair = try ProbeStore.shared.latestPair(app: app) else {
                throw ProbeError("\(app) needs two saved probes before a diff.")
            }
            let diff = ProbeDiff.compare(pair.0, pair.1)
            let payload: [String: Any] = [
                "before_gap_ms": diff.beforeGapMS,
                "after_gap_ms": diff.afterGapMS,
                "gap_delta_ms": diff.gapDeltaMS,
                "frames_added": diff.framesAdded,
                "frames_removed": diff.framesRemoved,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8) ?? "")
            return 0
        } catch {
            fputs("\(error)\n", stderr)
            return 2
        }
    }

    private static func runGate(_ args: [String]) -> Int32 {
        do {
            let request = try GateRequest.parse(args)
            let baseline = try request.app.flatMap { try ProbeStore.shared.reports(app: $0).last }
            let candidate = try Probe.hang(app: request.app, seconds: request.seconds, thresholdMS: request.maxGapMS)
            try ProbeStore.shared.append(candidate)
            let verdict = RegressionGate.evaluate(
                baseline: baseline,
                candidate: candidate,
                maxGapMS: request.maxGapMS,
                maxRegressionMS: request.maxRegressionMS
            )
            var payload: [String: Any] = [
                "passed": verdict.passed,
                "candidate_gap_ms": verdict.candidateGapMS,
                "max_gap_ms": verdict.maxGapMS,
                "max_regression_ms": verdict.maxRegressionMS,
                "reason": verdict.reason,
                "kind": candidate.kind.rawValue,
                "top": candidate.top,
            ]
            if let base = verdict.baselineGapMS { payload["baseline_gap_ms"] = base }
            if let delta = verdict.deltaMS { payload["delta_ms"] = delta }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8) ?? "")
            return verdict.passed ? 0 : 1
        } catch {
            fputs("\(error)\n", stderr)
            return 2
        }
    }

    private static func runImport(_ args: [String]) -> Int32 {
        do {
            let request = try ImportRequest.parse(args)
            let data = try Data(contentsOf: URL(fileURLWithPath: request.path))
            let rawReports = try MetricKitHangImporter.parse(data, thresholdMS: request.threshold)
            var out: [HangReport] = []
            for raw in rawReports {
                let symbolicated = Symbolicator.symbolicateReport(raw, dsymPath: request.dsym, ndkSymbolsPath: request.ndkSymbols)
                _ = try PhoneInboxStore.shared.save(symbolicated)
                out.append(symbolicated)
            }
            if out.count == 1 {
                try printJSON(out[0])
                return ProbeExit.code(for: out[0])
            }
            let encoded = try JSONEncoder().encode(out)
            let obj = try JSONSerialization.jsonObject(with: encoded)
            let pretty = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            print(String(data: pretty, encoding: .utf8) ?? "")
            return out.contains(where: \.hung) ? 1 : 0
        } catch {
            fputs("\(error)\n", stderr)
            return 2
        }
    }

    private static func runAppExit(_ args: [String]) -> Int32 {
        do {
            let pkg = args.first(where: { !$0.hasPrefix("-") })
            let reports = try AndroidDevices.pullExitInfoANRs(package: pkg)
            for item in reports {
                _ = try PhoneInboxStore.shared.save(item)
            }
            let encoded = try JSONEncoder().encode(reports)
            let obj = try JSONSerialization.jsonObject(with: encoded)
            let pretty = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            print(String(data: pretty, encoding: .utf8) ?? "")
            return reports.isEmpty ? 0 : 1
        } catch {
            fputs("\(error)\n", stderr)
            return 2
        }
    }

    private static func runInbox(_ args: [String]) -> Int32 {
        do {
            let request = try InboxRequest.parse(args)
            if request.listOnly {
                let reports = PhoneInboxStore.shared.allReports(limit: 25)
                let encoded = try JSONEncoder().encode(reports)
                let obj = try JSONSerialization.jsonObject(with: encoded)
                let pretty = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
                print(String(data: pretty, encoding: .utf8) ?? "")
                return 0
            }
            let server = PhoneInboxServer(
                port: request.port,
                localhostOnly: request.localhostOnly,
                authToken: request.authToken,
                dsymPath: request.dsym,
                ndkSymbolsPath: request.ndkSymbols,
                onReport: { report in
                    let app = report.app ?? "device"
                    fputs("[\(report.kind.rawValue)] \(app) · \(report.mainGapMS) ms · \(report.top)\n", stderr)
                }
            )
            try server.start()
            let authNote = request.authToken == nil ? "no auth token" : "token required"
            fputs(
                "Hangprobe phone inbox listening on \(server.listenURL) (\(request.localhostOnly ? "loopback" : "all interfaces") · \(authNote) · Bonjour _hangprobe._tcp)\n",
                stderr
            )
            dispatchMain()
        } catch {
            fputs("\(error)\n", stderr)
            return 2
        }
    }

    private static func runVersion(_ args: [String]) -> Int32 {
        if let sub = args.first {
            fputs("Usage: hangprobe version\nUnknown argument \(sub).\n", stderr)
            return 2
        }
        let payload: [String: Any] = [
            "name": "hangprobe",
            "version": HangprobeVersion.marketing,
            "license": "MIT",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            print(String(data: data, encoding: .utf8) ?? "")
        }
        return 0
    }

    private static func printJSON(_ report: HangReport) throws {
        let data = try JSONEncoder().encode(report)
        let object = try JSONSerialization.jsonObject(with: data)
        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        print(String(data: pretty, encoding: .utf8) ?? "")
    }
}

private struct Request {
    var app: String?
    var seconds: Int
    var threshold: Int

    static func parse(_ args: [String]) throws -> Request {
        var app: String?
        var seconds = 1
        var threshold = 250
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--seconds" {
                index += 1
                guard index < args.count, let value = Int(args[index]) else { throw ProbeError("seconds must be 1, 2, or 3.") }
                seconds = value
            } else if arg == "--threshold-ms" {
                index += 1
                guard index < args.count, let value = Int(args[index]) else { throw ProbeError("threshold_ms must be between 50 and 3000.") }
                threshold = value
            } else if arg.hasPrefix("-") {
                throw ProbeError("Usage: hangprobe probe [app] [--seconds 1] [--threshold-ms 250]")
            } else if app == nil {
                app = arg
            } else {
                throw ProbeError("Usage: hangprobe probe [app] [--seconds 1] [--threshold-ms 250]")
            }
            index += 1
        }
        return Request(app: app, seconds: seconds, threshold: threshold)
    }
}

private struct GateRequest {
    var app: String?
    var seconds: Int = 1
    var maxGapMS: Int = 250
    var maxRegressionMS: Int = 50

    static func parse(_ args: [String]) throws -> GateRequest {
        var req = GateRequest()
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--seconds":
                index += 1
                guard index < args.count, let val = Int(args[index]) else { throw ProbeError("seconds must be 1, 2, or 3.") }
                req.seconds = val
            case "--max-gap-ms", "--threshold-ms":
                index += 1
                guard index < args.count, let val = Int(args[index]) else { throw ProbeError("max-gap-ms must be an integer.") }
                req.maxGapMS = val
            case "--max-regression-ms":
                index += 1
                guard index < args.count, let val = Int(args[index]) else { throw ProbeError("max-regression-ms must be an integer.") }
                req.maxRegressionMS = val
            default:
                if arg.hasPrefix("-") || req.app != nil {
                    throw ProbeError("Usage: hangprobe gate [app] [--seconds 1] [--max-gap-ms 250] [--max-regression-ms 50]")
                }
                req.app = arg
            }
            index += 1
        }
        return req
    }
}

private struct ImportRequest {
    var path: String
    var threshold: Int = 250
    var dsym: String?
    var ndkSymbols: String?

    static func parse(_ args: [String]) throws -> ImportRequest {
        var path: String?
        var threshold = 250
        var dsym: String?
        var ndk: String?
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--threshold-ms":
                index += 1
                guard index < args.count, let val = Int(args[index]) else { throw ProbeError("threshold_ms must be an integer.") }
                threshold = val
            case "--dsym":
                index += 1
                guard index < args.count else { throw ProbeError("--dsym needs a path.") }
                dsym = args[index]
            case "--ndk-symbols":
                index += 1
                guard index < args.count else { throw ProbeError("--ndk-symbols needs a path.") }
                ndk = args[index]
            default:
                if arg.hasPrefix("-") || path != nil {
                    throw ProbeError("Usage: hangprobe import <mxhang.json> [--dsym App.dSYM] [--threshold-ms 250]")
                }
                path = arg
            }
            index += 1
        }
        guard let path else {
            throw ProbeError("Usage: hangprobe import <mxhang.json> [--dsym App.dSYM] [--threshold-ms 250]")
        }
        return ImportRequest(path: path, threshold: threshold, dsym: dsym, ndkSymbols: ndk)
    }
}

private struct InboxRequest {
    var port: UInt16 = 9481
    var localhostOnly: Bool = true
    var authToken: String? = ProcessInfo.processInfo.environment["HANGPROBE_INBOX_TOKEN"]
    var dsym: String?
    var ndkSymbols: String?
    var listOnly: Bool = false

    static func parse(_ args: [String]) throws -> InboxRequest {
        var req = InboxRequest()
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--port":
                index += 1
                guard index < args.count, let val = UInt16(args[index]) else { throw ProbeError("--port must be 1..65535.") }
                req.port = val
            case "--bind":
                index += 1
                guard index < args.count else { throw ProbeError("--bind needs localhost|all.") }
                switch args[index].lowercased() {
                case "localhost", "loopback", "127.0.0.1":
                    req.localhostOnly = true
                case "all", "0.0.0.0", "any":
                    req.localhostOnly = false
                default:
                    throw ProbeError("--bind must be localhost or all.")
                }
            case "--token":
                index += 1
                guard index < args.count else { throw ProbeError("--token needs a value.") }
                req.authToken = args[index]
            case "--dsym":
                index += 1
                guard index < args.count else { throw ProbeError("--dsym needs a path.") }
                req.dsym = args[index]
            case "--ndk-symbols":
                index += 1
                guard index < args.count else { throw ProbeError("--ndk-symbols needs a path.") }
                req.ndkSymbols = args[index]
            case "--list":
                req.listOnly = true
            default:
                throw ProbeError("Usage: hangprobe inbox [--port 9481] [--bind localhost|all] [--token SECRET] [--dsym App.dSYM] [--ndk-symbols dir] [--list]")
            }
            index += 1
        }
        return req
    }
}

enum AppLauncher {
    static func open() throws -> Int32 {
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("HangprobeApp")
        guard FileManager.default.isExecutableFile(atPath: sibling.path) else {
            throw ProbeError("HangprobeApp is not next to this binary. Build it with swift build.")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let app = support.appendingPathComponent("Hangprobe/Hangprobe.app", isDirectory: true)
        let macos = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        let binary = macos.appendingPathComponent("Hangprobe")
        try? FileManager.default.removeItem(at: app)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sibling, to: binary)

        // SPM resource bundle (IBM Plex fonts) must sit next to the executable for Bundle.module.
        let resourceBundleName = "Hangprobe_HangprobeApp.bundle"
        let siblingBundle = sibling.deletingLastPathComponent().appendingPathComponent(resourceBundleName)
        if FileManager.default.fileExists(atPath: siblingBundle.path) {
            try? FileManager.default.copyItem(
                at: siblingBundle,
                to: macos.appendingPathComponent(resourceBundleName)
            )
        }

        let candidateRoots = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent(),
        ]
        if let iconURL = candidateRoots
            .map({ $0.appendingPathComponent("assets/AppIcon.icns") })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
        {
            try? FileManager.default.copyItem(at: iconURL, to: resources.appendingPathComponent("AppIcon.icns"))
        }

        let fontsDest = resources.appendingPathComponent("Fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: fontsDest, withIntermediateDirectories: true)
        for root in candidateRoots {
            let fontsDir = root.appendingPathComponent("assets/fonts", isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: fontsDir,
                includingPropertiesForKeys: nil
            ) else { continue }
            for file in files where file.pathExtension.lowercased() == "otf" {
                let dest = fontsDest.appendingPathComponent(file.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.copyItem(at: file, to: dest)
            }
            if FileManager.default.fileExists(atPath: fontsDir.appendingPathComponent("OFL-IBM-Plex.txt").path) {
                try? FileManager.default.copyItem(
                    at: fontsDir.appendingPathComponent("OFL-IBM-Plex.txt"),
                    to: fontsDest.appendingPathComponent("OFL-IBM-Plex.txt")
                )
            }
            break
        }

        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleExecutable</key><string>Hangprobe</string>
          <key>CFBundleIconFile</key><string>AppIcon</string>
          <key>CFBundleIdentifier</key><string>com.hangprobe.app</string>
          <key>CFBundleName</key><string>Hangprobe</string>
          <key>CFBundlePackageType</key><string>APPL</string>
          <key>CFBundleShortVersionString</key><string>\(HangprobeVersion.marketing)</string>
          <key>CFBundleVersion</key><string>\(HangprobeVersion.marketing)</string>
          <key>ATSApplicationFontsPath</key><string>Fonts</string>
          <key>LSMinimumSystemVersion</key><string>14.0</string>
          <key>NSHighResolutionCapable</key><true/>
        </dict>
        </plist>
        """.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        let result = try Shell.run(["/usr/bin/open", app.path], timeout: 10)
        return result.status
    }
}
