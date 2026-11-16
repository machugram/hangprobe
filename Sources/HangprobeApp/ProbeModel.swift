import AppKit
import Foundation
import HangprobeCore
import UniformTypeIdentifiers

enum InspectorTab: String, CaseIterable, Identifiable {
    case appFocus = "App Focus"
    case fullStack = "Full Stack"
    case hotspots = "Hotspots"
    case history = "Diff & Trend"

    var id: String { rawValue }
}

@MainActor
@Observable
final class ProbeModel {
    var apps: [RunningApp] = []
    var inboxReports: [HangReport] = []
    var appHistory: [HangReport] = []
    var selection: String? {
        didSet {
            syncSelection()
            persistSelectionHint()
        }
    }
    var sidebarQuery = ""
    var stackFilter = "" {
        didSet { DeskPreferences.stackFilter = stackFilter }
    }
    var inspectorTab: InspectorTab = .appFocus {
        didSet { DeskPreferences.inspectorTab = inspectorTab }
    }
    var leafFirst = true {
        didSet { DeskPreferences.leafFirst = leafFirst }
    }
    var seconds = 1 {
        didSet { DeskPreferences.seconds = seconds }
    }
    var threshold = 250 {
        didSet { DeskPreferences.threshold = threshold }
    }
    var report: HangReport?
    var earlier: HangReport?
    var error: String?
    var running = false
    var runningLabel = "Sampling..."
    var watchAttempt = 0
    var inboxListening = false
    var appearance: AppearanceMode = .system {
        didSet { DeskPreferences.appearance = appearance }
    }
    var showAboutSheet = false
    var status = "Select a running target and press ⌘R to probe."

    private var inboxServer: PhoneInboxServer?
    private var targetRefreshTask: Task<Void, Never>?
    private var suppressPersist = false

    init() {
        suppressPersist = true
        seconds = DeskPreferences.seconds
        threshold = DeskPreferences.threshold
        appearance = DeskPreferences.appearance
        leafFirst = DeskPreferences.leafFirst
        stackFilter = DeskPreferences.stackFilter
        inspectorTab = DeskPreferences.inspectorTab
        suppressPersist = false
    }

    func startTargetRefresh() {
        targetRefreshTask?.cancel()
        targetRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await MainActor.run {
                    self?.reload(quiet: true)
                }
            }
        }
    }

    func stopTargetRefresh() {
        targetRefreshTask?.cancel()
        targetRefreshTask = nil
    }





    var selected: RunningApp? {
        guard let selection, !selection.hasPrefix("inbox:") else { return nil }
        return apps.first { $0.id == selection }
    }

    var filteredApps: [RunningApp] {
        let q = sidebarQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return apps }
        return apps.filter { item in
            item.app.lowercased().contains(q)
                || (item.bundleID?.lowercased().contains(q) == true)
                || String(item.pid).contains(q)
                || item.place.rawValue.contains(q)
        }
    }

    var filteredInbox: [(offset: Int, element: HangReport)] {
        let q = sidebarQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pairs = Array(inboxReports.enumerated())
        guard !q.isEmpty else { return pairs }
        return pairs.filter { _, item in
            (item.app?.lowercased().contains(q) == true)
                || item.top.lowercased().contains(q)
                || item.kind.rawValue.contains(q)
        }
    }

    func reload(quiet: Bool = false) {
        let currentApps = ProcessList.current().filter { $0.bundleID != "com.hangprobe.app" && $0.app != "Hangprobe" }
        let previousSelection = selection
        self.apps = currentApps
        self.inboxReports = PhoneInboxStore.shared.allReports(limit: 25)

        // Don't steal focus mid-sample if the PID briefly flickers out of the list.
        if running {
            return
        }

        let selectionStillValid = previousSelection.map { id in
            id.hasPrefix("inbox:") || currentApps.contains(where: { $0.id == id })
        } ?? false

        if !selectionStillValid {
            if let restored = DeskPreferences.selectionHint.flatMap({ DeskPreferences.match($0, in: currentApps) }) {
                selection = restored.id
            } else if let front = frontmostMatch(in: currentApps) {
                selection = front.id
            } else {
                selection = currentApps.first { $0.place == .simulator }?.id ?? currentApps.first?.id
            }
        } else if !quiet {
            syncSelection()
        }

        if !quiet, currentApps.isEmpty && inboxReports.isEmpty {
            status = "No foreground app is running."
        }
    }

    private func frontmostMatch(in apps: [RunningApp]) -> RunningApp? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        if front.bundleIdentifier == "com.hangprobe.app" { return nil }
        if let bundle = front.bundleIdentifier,
           let hit = apps.first(where: { $0.bundleID == bundle }) {
            return hit
        }
        return apps.first { $0.pid == front.processIdentifier }
    }

    private func persistSelectionHint() {
        guard !suppressPersist, let target = selected else { return }
        DeskPreferences.selectionHint = DeskPreferences.hint(from: target)
    }

    private func syncSelection() {
        guard let selection else { return }
        if selection.hasPrefix("inbox:"), let idx = Int(selection.dropFirst("inbox:".count)), inboxReports.indices.contains(idx) {
            let chosen = inboxReports[idx]
            report = chosen
            refreshHistory(for: chosen.app)
            error = nil
            status = "Inbox · \(chosen.app ?? "Device") · \(chosen.kind.rawValue) (\(chosen.mainGapMS) ms)."
        } else if let target = apps.first(where: { $0.id == selection }) {
            refreshHistory(for: target.app)
            if report?.app != target.app {
                report = appHistory.last
                earlier = appHistory.count >= 2 ? appHistory[appHistory.count - 2] : nil
            }
            if !running {
                status = "Ready to probe \(target.app) (pid \(target.pid))."
            }
        }
    }

    private func refreshHistory(for appName: String?) {
        guard let appName, !appName.isEmpty else {
            appHistory = []
            return
        }
        let stored = (try? ProbeStore.shared.reports(app: appName)) ?? []
        appHistory = Array(stored.suffix(14))
    }

    func selectHistoryReport(_ chosen: HangReport, index: Int) {
        report = chosen
        earlier = index > 0 ? appHistory[index - 1] : nil
        status = "Viewing saved run #\(index + 1) (\(chosen.mainGapMS) ms)."
    }

    func toggleInbox() {
        if inboxListening {
            inboxServer?.stop()
            inboxServer = nil
            inboxListening = false
            status = "Phone inbox stopped."
            return
        }
        let token = ProcessInfo.processInfo.environment["HANGPROBE_INBOX_TOKEN"]
        let server = PhoneInboxServer(
            port: 9481,
            localhostOnly: true,
            authToken: token
        ) { [weak self] incoming in
            Task { @MainActor in
                guard let self else { return }
                self.inboxReports = PhoneInboxStore.shared.allReports(limit: 25)
                self.earlier = self.report
                self.report = incoming
                self.refreshHistory(for: incoming.app)
                self.selection = "inbox:0"
                self.status = "Live hang from \(incoming.app ?? "device") · \(incoming.mainGapMS) ms."
            }
        }
        do {
            try server.start()
            inboxServer = server
            inboxListening = true
            let authNote = token?.isEmpty == false ? "token required" : "no auth token"
            status = "Listening on \(server.listenURL) (loopback · \(authNote) · Bonjour _hangprobe._tcp)."
        } catch {
            self.error = String(describing: error)
            status = "Could not start phone inbox."
        }
    }

    func importMetricKitFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a MetricKit MXHangDiagnostic or HangReport JSON file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let parsed: [HangReport]
            if let direct = try? JSONDecoder().decode(HangReport.self, from: data) {
                parsed = [direct]
            } else {
                parsed = try MetricKitHangImporter.parse(data, thresholdMS: threshold)
            }
            guard let first = parsed.first else { return }
            for item in parsed {
                _ = try PhoneInboxStore.shared.save(item)
            }
            inboxReports = PhoneInboxStore.shared.allReports(limit: 25)
            report = first
            refreshHistory(for: first.app)
            selection = "inbox:0"
            error = nil
            status = "Imported \(parsed.count) diagnostic report(s) (\(first.mainGapMS) ms)."
        } catch {
            self.error = String(describing: error)
            status = "Diagnostic import failed."
        }
    }

    func pullAndroidExitInfo() {
        guard !running else { return }
        let pkg = selected?.place == .android ? (selected?.bundleID ?? selected?.app) : nil
        running = true
        runningLabel = "Pulling adb exit-info..."
        error = nil
        Task.detached {
            do {
                let pulled = try AndroidDevices.pullExitInfoANRs(package: pkg)
                for item in pulled {
                    _ = try PhoneInboxStore.shared.save(item)
                }
                await MainActor.run {
                    self.running = false
                    self.inboxReports = PhoneInboxStore.shared.allReports(limit: 25)
                    if let first = pulled.first {
                        self.report = first
                        self.refreshHistory(for: first.app)
                        self.selection = "inbox:0"
                        self.status = "Pulled \(pulled.count) Android ApplicationExitInfo ANR(s)."
                    } else {
                        self.status = "No historical REASON_ANR records in dumpsys exit-info."
                    }
                }
            } catch {
                await MainActor.run {
                    self.running = false
                    self.error = String(describing: error)
                    self.status = "adb exit-info pull failed."
                }
            }
        }
    }

    func probe() {
        run(label: "Sampling \(seconds)s...") { app, seconds, threshold in
            try Probe.hang(app: app, seconds: seconds, thresholdMS: threshold)
        }
    }

    func watch() {
        watchAttempt = 0
        run(label: "Watching until hang…") { app, seconds, threshold in
            try Probe.watch(app: app, seconds: seconds, thresholdMS: threshold, pause: {
                Thread.sleep(forTimeInterval: 1.5)
            })
        }
    }

    func worst() {
        run(label: "Sampling 10s window...") { app, _, threshold in
            try Probe.worst(app: app, thresholdMS: threshold)
        }
    }

    func copyReport() {
        guard let report else { return }
        Pasteboard.copy(ReportExporter.markdown(report))
        status = "Copied Markdown report to clipboard."
    }

    func copyJSONReport() {
        guard let report, let data = try? ReportExporter.prettyJSON(report), let text = String(data: data, encoding: .utf8) else { return }
        Pasteboard.copy(text)
        status = "Copied JSON report to clipboard."
    }

    func exportReportFile() {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(report.app ?? "hangprobe")-\(report.kind.rawValue)-\(report.mainGapMS)ms.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try ReportExporter.prettyJSON(report)
            try data.write(to: url)
            status = "Saved \(url.lastPathComponent)."
        } catch {
            self.error = String(describing: error)
            status = "Could not save report."
        }
    }

    func exportMarkdownFile() {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(report.app ?? "hangprobe")-\(report.kind.rawValue)-\(report.mainGapMS)ms.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ReportExporter.markdown(report).write(to: url, atomically: true, encoding: .utf8)
            status = "Saved \(url.lastPathComponent)."
        } catch {
            self.error = String(describing: error)
            status = "Could not save Markdown."
        }
    }

    func dismissError() {
        error = nil
    }

    /// Prefer Diff after a hang when a prior run exists; otherwise stay on App Focus.
    func focusAfterCapture(_ captured: HangReport) {
        if captured.hung, earlier != nil {
            inspectorTab = .history
        } else if captured.hung {
            inspectorTab = .appFocus
        }
    }

    func copySymbol(_ text: String) {
        Pasteboard.copy(text)
        status = "Copied \(text)."
    }

    func loadShowcase(_ kind: HangKind) {
        let busySample = HangReport(
            hung: true,
            kind: .busy,
            mainGapMS: 840,
            gapAtLeast: true,
            busyMS: 840,
            blockedMS: 0,
            eventWaitMS: 80,
            windowMS: 920,
            thresholdMS: threshold,
            samples: 92,
            top: "SportProfileEditorView.body.getter",
            stack: [
                "UIApplicationMain (in UIKitCore)",
                "GSEventRunModal (in GraphicsServices)",
                "__CFRunLoopRun (in CoreFoundation)",
                "__CFRunLoopDoObservers (in CoreFoundation)",
                "CA::Transaction::commit() (in QuartzCore)",
                "-[UIView layoutSubviews] (in UIKitCore)",
                "SportProfileEditorView.recomputeMetrics() (in HangDemo)",
                "SportProfileEditorView.body.getter (in HangDemo)",
            ],
            pid: 55102,
            app: "HangDemo",
            bundleID: "com.example.hangdemo",
            place: .simulator,
            note: "Preview · Layout pass stayed on-CPU across 84 of 92 samples.",
            context: HangContext(commit: "8f3c12a", screen: "SportProfileEditorView", device: "iPhone 17 Pro Sim", os: "iOS 20.1", arch: "arm64"),
            hotspots: [
                FrameHotspot(frame: "SportProfileEditorView.body.getter (in HangDemo)", hits: 84, totalSamples: 92),
                FrameHotspot(frame: "SportProfileEditorView.recomputeMetrics() (in HangDemo)", hits: 79, totalSamples: 92),
                FrameHotspot(frame: "-[UIView layoutSubviews] (in UIKitCore)", hits: 84, totalSamples: 92),
                FrameHotspot(frame: "__CFRunLoopServiceMachPort (in CoreFoundation)", hits: 8, totalSamples: 92),
            ]
        )

        let blockedSample = HangReport(
            hung: true,
            kind: .blocked,
            mainGapMS: 930,
            gapAtLeast: true,
            busyMS: 0,
            blockedMS: 930,
            eventWaitMS: 0,
            windowMS: 930,
            thresholdMS: threshold,
            samples: 93,
            top: "__psynch_mutexwait",
            stack: [
                "UIApplicationMain (in UIKitCore)",
                "__CFRunLoopRun (in CoreFoundation)",
                "__CFRunLoopDoSources0 (in CoreFoundation)",
                "__CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE0_PERFORM_FUNCTION__ (in CoreFoundation)",
                "-[CatalogStore syncMainThread] (in HangDemo)",
                "_pthread_mutex_firstfit_lock_slow (in libsystem_pthread.dylib)",
                "__psynch_mutexwait (in libsystem_kernel.dylib)",
            ],
            pid: 55102,
            app: "HangDemo",
            bundleID: "com.example.hangdemo",
            place: .simulator,
            note: "Preview · Main thread parked on a contended mutex inside a Source0 callback.",
            context: HangContext(commit: "8f3c12a", screen: "CatalogSheet", device: "iPhone 17 Pro Sim", os: "iOS 20.1", arch: "arm64"),
            hotspots: [
                FrameHotspot(frame: "__psynch_mutexwait (in libsystem_kernel.dylib)", hits: 93, totalSamples: 93),
                FrameHotspot(frame: "-[CatalogStore syncMainThread] (in HangDemo)", hits: 93, totalSamples: 93),
            ]
        )

        let responsiveSample = HangReport(
            hung: false,
            kind: .responsive,
            mainGapMS: 20,
            gapAtLeast: false,
            busyMS: 20,
            blockedMS: 0,
            eventWaitMS: 890,
            windowMS: 910,
            thresholdMS: threshold,
            samples: 91,
            top: "mach_msg2_trap",
            stack: [
                "UIApplicationMain (in UIKitCore)",
                "GSEventRunModal (in GraphicsServices)",
                "__CFRunLoopRun (in CoreFoundation)",
                "__CFRunLoopServiceMachPort (in CoreFoundation)",
                "mach_msg2_trap (in libsystem_kernel.dylib)",
            ],
            pid: 55102,
            app: "HangDemo",
            bundleID: "com.example.hangdemo",
            place: .simulator,
            note: "Preview · Fix verified: main thread spent 98% of the window parked cleanly in the event loop.",
            context: HangContext(commit: "94d01ef", screen: "SportProfileEditorView", device: "iPhone 17 Pro Sim", os: "iOS 20.1", arch: "arm64"),
            hotspots: [
                FrameHotspot(frame: "mach_msg2_trap (in libsystem_kernel.dylib)", hits: 89, totalSamples: 91),
                FrameHotspot(frame: "__CFRunLoopServiceMachPort (in CoreFoundation)", hits: 89, totalSamples: 91),
            ]
        )

        error = nil
        // Showcase is not tied to a live sidebar row — clear selection so the
        // nav title falls through to report.app (HangDemo) instead of the last probe target.
        selection = nil
        appHistory = [blockedSample, busySample, responsiveSample]
        switch kind {
        case .busy:
            earlier = blockedSample
            report = busySample
            status = "Showing CPU layout-loop hang preview (840 ms)."
        case .blocked:
            earlier = nil
            report = blockedSample
            status = "Showing mutex contention hang preview (930 ms)."
        case .responsive:
            earlier = busySample
            report = responsiveSample
            status = "Showing verified fix preview (840 ms → 20 ms)."
        }
    }

    private func run(label: String, _ work: @escaping @Sendable (String?, Int, Int) throws -> HangReport) {
        guard !running else { return }
        guard let app = selected else {
            status = "Pick a live Simulator, Mac, or Android process in the sidebar."
            return
        }
        let query = app.bundleID ?? app.app
        let seconds = seconds
        let threshold = min(max(threshold, 50), 3000)
        self.threshold = threshold
        running = true
        runningLabel = label
        error = nil
        status = "\(label) (\(app.app), pid \(app.pid))"
        let previous = appHistory.last ?? report

        Task.detached {
            do {
                let captured = try work(query, seconds, threshold)
                try? ProbeStore.shared.append(captured)
                await MainActor.run {
                    self.earlier = previous
                    self.report = captured
                    self.refreshHistory(for: captured.app ?? app.app)
                    self.running = false
                    self.watchAttempt = 0
                    self.focusAfterCapture(captured)
                    self.status = captured.hung
                        ? "Hung (\(captured.kind.rawValue)) · \(captured.mainGapMS) ms · copy the culprit or re-probe after your fix."
                        : "Responsive · \(captured.mainGapMS) ms off the event loop."
                }
            } catch {
                await MainActor.run {
                    self.running = false
                    self.watchAttempt = 0
                    // Keep the last good report visible; surface the failure as a banner.
                    self.error = String(describing: error)
                    self.status = "Probe failed — last report kept."
                    self.reload(quiet: true)
                }
            }
        }
    }
}
