import Foundation

public enum HangKind: String, Codable, Equatable, Sendable {
    case busy
    case blocked
    case responsive
}

public enum ProbePlace: String, Codable, Equatable, Sendable {
    case mac
    case simulator
    case android
    case ios
}

public enum HangSeverity: String, Codable, Equatable, Sendable {
    case healthy = "healthy"
    case appleHang = "apple_hang"
    case severeHang = "severe_hang"
    case androidANR = "android_anr"

    public var label: String {
        switch self {
        case .healthy: return "Healthy (< threshold)"
        case .appleHang: return "UI Hang (>= 250 ms)"
        case .severeHang: return "Severe Freeze (>= 1s)"
        case .androidANR: return "Play Vitals ANR (>= 5s)"
        }
    }
}

public struct FrameHotspot: Codable, Equatable, Sendable, Identifiable {
    public var frame: String
    public var hits: Int
    public var totalSamples: Int

    public var id: String { frame }
    public var share: Double {
        guard totalSamples > 0 else { return 0 }
        return Double(hits) / Double(totalSamples)
    }
    public var percent: Int {
        Int((share * 100.0).rounded())
    }

    public init(frame: String, hits: Int, totalSamples: Int) {
        self.frame = frame
        self.hits = hits
        self.totalSamples = totalSamples
    }

    enum CodingKeys: String, CodingKey {
        case frame, hits
        case totalSamples = "total_samples"
    }
}

public struct HangContext: Codable, Equatable, Sendable {
    public var commit: String?
    public var screen: String?
    public var device: String?
    public var os: String?
    public var arch: String?
    public var loadAddress: String?
    public var binaryUUID: String?
    public var capturedAt: String?

    public init(
        commit: String? = nil,
        screen: String? = nil,
        device: String? = nil,
        os: String? = nil,
        arch: String? = nil,
        loadAddress: String? = nil,
        binaryUUID: String? = nil,
        capturedAt: String? = nil
    ) {
        self.commit = commit
        self.screen = screen
        self.device = device
        self.os = os
        self.arch = arch
        self.loadAddress = loadAddress
        self.binaryUUID = binaryUUID
        self.capturedAt = capturedAt
    }

    enum CodingKeys: String, CodingKey {
        case commit, screen, device, os, arch
        case loadAddress = "load_address"
        case binaryUUID = "binary_uuid"
        case capturedAt = "captured_at"
    }
}

public struct HangReport: Codable, Equatable, Sendable {
    public var hung: Bool
    public var kind: HangKind
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
    public var pid: Int?
    public var app: String?
    public var bundleID: String?
    public var place: ProbePlace?
    public var note: String?
    public var context: HangContext?
    public var hotspots: [FrameHotspot]?

    public var severity: HangSeverity {
        if !hung { return .healthy }
        if place == .android && (mainGapMS >= 5000 || (note?.contains("ANR") == true && mainGapMS >= 4500)) {
            return .androidANR
        }
        if mainGapMS >= 1000 { return .severeHang }
        return .appleHang
    }

    public init(
        hung: Bool,
        kind: HangKind,
        mainGapMS: Int,
        gapAtLeast: Bool,
        busyMS: Int,
        blockedMS: Int,
        eventWaitMS: Int,
        windowMS: Int,
        thresholdMS: Int,
        samples: Int,
        top: String,
        stack: [String],
        pid: Int? = nil,
        app: String? = nil,
        bundleID: String? = nil,
        place: ProbePlace? = nil,
        note: String? = nil,
        context: HangContext? = nil,
        hotspots: [FrameHotspot]? = nil
    ) {
        self.hung = hung
        self.kind = kind
        self.mainGapMS = mainGapMS
        self.gapAtLeast = gapAtLeast
        self.busyMS = busyMS
        self.blockedMS = blockedMS
        self.eventWaitMS = eventWaitMS
        self.windowMS = windowMS
        self.thresholdMS = thresholdMS
        self.samples = samples
        self.top = top
        self.stack = stack
        self.pid = pid
        self.app = app
        self.bundleID = bundleID
        self.place = place
        self.note = note
        self.context = context
        self.hotspots = hotspots
    }

    enum CodingKeys: String, CodingKey {
        case hung, kind, top, stack, pid, app, note, context, hotspots
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

public enum ProbeExit {
    public static func code(for report: HangReport) -> Int32 {
        report.hung ? 1 : 0
    }
}
