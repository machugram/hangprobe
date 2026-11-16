// SPDX-License-Identifier: MIT
// MIT device SDK (oss/HangprobeKit) — standalone watchdog, dependency-light.

import Foundation
#if canImport(Darwin)
import Darwin
import MachO
#endif

public struct HangprobeWatchdogConfig: Sendable {
    public var endpoint: URL
    public var thresholdMS: Int
    public var pollIntervalMS: Int
    public var appName: String
    public var bundleID: String?
    public var commit: String?
    public var currentScreen: (@Sendable () -> String?)?

    public init(
        endpoint: URL = URL(string: "http://127.0.0.1:9481/v1/hangs")!,
        thresholdMS: Int = 250,
        pollIntervalMS: Int = 50,
        appName: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName,
        bundleID: String? = Bundle.main.bundleIdentifier,
        commit: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
        currentScreen: (@Sendable () -> String?)? = nil
    ) {
        self.endpoint = endpoint
        self.thresholdMS = max(50, thresholdMS)
        self.pollIntervalMS = max(20, pollIntervalMS)
        self.appName = appName
        self.bundleID = bundleID
        self.commit = commit
        self.currentScreen = currentScreen
    }
}

public struct WatchdogPayload: Codable, Equatable, Sendable {
    public var hung: Bool
    public var kind: String
    public var mainGapMS: Int
    public var gapAtLeast: Bool
    public var busyMS: Int
    public var blockedMS: Int
    public var eventWaitMS: Int
    public var windowMS: Int
    public var thresholdMS: Int
    public var samples: Int
    public var top: String
    public var stack: [String]
    public var pid: Int
    public var app: String
    public var bundleID: String?
    public var place: String
    public var note: String
    public var context: PayloadContext

    public struct PayloadContext: Codable, Equatable, Sendable {
        public var commit: String?
        public var screen: String?
        public var device: String?
        public var os: String?
        public var arch: String?
        public var loadAddress: String?
        public var capturedAt: String

        enum CodingKeys: String, CodingKey {
            case commit, screen, device, os, arch
            case loadAddress = "load_address"
            case capturedAt = "captured_at"
        }
    }

    enum CodingKeys: String, CodingKey {
        case hung, kind, top, stack, pid, app, note, context
        case mainGapMS = "main_gap_ms"
        case gapAtLeast = "gap_at_least"
        case busyMS = "busy_ms"
        case blockedMS = "blocked_ms"
        case eventWaitMS = "event_wait_ms"
        case windowMS = "window_ms"
        case thresholdMS = "threshold_ms"
        case samples
        case bundleID = "bundle_id"
        case place = "where"
    }
}

/// MIT debug watchdog for iOS and macOS apps.
/// Strips itself to a zero-allocation no-op in Release builds unless `allowInRelease` is explicitly set.
public final class HangprobeWatchdog: @unchecked Sendable {
    public static let shared = HangprobeWatchdog()

    private let lock = NSLock()
    private var running = false
    private var worker: Thread?

    public init() {}

    public func start(
        config: HangprobeWatchdogConfig = HangprobeWatchdogConfig(),
        allowInRelease: Bool = false,
        transport: (@Sendable (WatchdogPayload) -> Void)? = nil
    ) {
        #if !DEBUG
        if !allowInRelease { return }
        #endif
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        running = true
        lock.unlock()

        let sender = transport ?? { payload in
            Self.post(payload, to: config.endpoint)
        }

        let thread = Thread { [weak self] in
            self?.loop(config: config, send: sender)
        }
        thread.name = "com.hangprobe.watchdog"
        thread.qualityOfService = .utility
        worker = thread
        thread.start()
    }

    public func stop() {
        lock.lock()
        running = false
        lock.unlock()
        worker?.cancel()
        worker = nil
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func loop(config: HangprobeWatchdogConfig, send: @Sendable (WatchdogPayload) -> Void) {
        let pollSeconds = Double(config.pollIntervalMS) / 1000.0
        let thresholdSeconds = Double(config.thresholdMS) / 1000.0

        while isRunning && !Thread.current.isCancelled {
            let answered = FlagBox()
            let pingStart = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                answered.mark()
            }

            var reportedForStall = false
            var capturedFrames: [String] = []

            while isRunning && !answered.value {
                Thread.sleep(forTimeInterval: pollSeconds)
                let elapsed = ProcessInfo.processInfo.systemUptime - pingStart
                if elapsed >= thresholdSeconds && !reportedForStall {
                    reportedForStall = true
                    capturedFrames = Self.snapshotFrames(appName: config.appName)
                    let gapMS = Int((elapsed * 1000.0).rounded())
                    let payload = Self.buildPayload(
                        gapMS: gapMS,
                        gapAtLeast: true,
                        frames: capturedFrames,
                        config: config
                    )
                    send(payload)
                }
            }

            Thread.sleep(forTimeInterval: pollSeconds)
        }
    }

    public static func buildPayload(
        gapMS: Int,
        gapAtLeast: Bool,
        frames: [String],
        config: HangprobeWatchdogConfig
    ) -> WatchdogPayload {
        let clean = frames.isEmpty ? ["0x0 (in \(config.appName))"] : Array(frames.suffix(16))
        let leaf = clean.last ?? ""
        let lower = leaf.lowercased()
        let isBlocked = lower.contains("mutex") || lower.contains("semaphore") || lower.contains("ulock") || lower.contains("psynch") || lower.contains("sleep")
        let kind = isBlocked ? "blocked" : "busy"
        let top = leaf.components(separatedBy: " (in ").first?.trimmingCharacters(in: .whitespaces) ?? leaf
        #if os(iOS)
        let place = "ios"
        #else
        let place = "mac"
        #endif
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "unknown"
        #endif

        return WatchdogPayload(
            hung: gapMS >= config.thresholdMS,
            kind: gapMS >= config.thresholdMS ? kind : "responsive",
            mainGapMS: gapMS,
            gapAtLeast: gapAtLeast,
            busyMS: kind == "busy" ? gapMS : 0,
            blockedMS: kind == "blocked" ? gapMS : 0,
            eventWaitMS: 0,
            windowMS: gapMS,
            thresholdMS: config.thresholdMS,
            samples: 1,
            top: top,
            stack: clean,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            app: config.appName,
            bundleID: config.bundleID,
            place: place,
            note: "Debug watchdog report (threshold \(config.thresholdMS) ms, zero session metering).",
            context: WatchdogPayload.PayloadContext(
                commit: config.commit,
                screen: config.currentScreen?(),
                device: machineModel(),
                os: ProcessInfo.processInfo.operatingSystemVersionString,
                arch: arch,
                loadAddress: mainImageLoadAddress(),
                capturedAt: ISO8601DateFormatter().string(from: Date())
            )
        )
    }

    private static func snapshotFrames(appName: String) -> [String] {
        let load = mainImageLoadAddress() ?? "0x100000000"
        return ["\(load) (in \(appName))"]
    }

    private static func mainImageLoadAddress() -> String? {
        #if canImport(MachO)
        let count = _dyld_image_count()
        for index in 0..<count {
            guard let header = _dyld_get_image_header(index) else { continue }
            if header.pointee.filetype == MH_EXECUTE {
                return String(format: "0x%llx", UInt64(UInt(bitPattern: header)))
            }
        }
        #endif
        return nil
    }

    private static func machineModel() -> String {
        #if canImport(Darwin)
        var size: Int = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.machine", &buffer, &size, nil, 0)
            return String(cString: buffer)
        }
        #endif
        return "apple-device"
    }

    private static func post(_ payload: WatchdogPayload, to endpoint: URL) {
        guard let body = try? JSONEncoder().encode(payload) else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 4
        URLSession.shared.dataTask(with: request).resume()
    }
}

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func mark() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}
