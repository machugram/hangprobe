import AppKit
import HangprobeCore
import SwiftUI

struct ProbeWindow: View {
    @State private var model = ProbeModel()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .background(WindowAccessor(report: model.report))
        .preferredColorScheme(model.appearance.colorScheme)
        .sheet(isPresented: $model.showAboutSheet) {
            AboutSheetView(model: model)
        }
        .task {
            model.reload()
            model.startTargetRefresh()
        }
        .onDisappear { model.stopTargetRefresh() }
        .toolbar { toolbarContent }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $model.selection) {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.apps) { app in
                        SidebarTargetRow(
                            title: app.app,
                            subtitle: app.place == .android ? (app.serial ?? "adb") : (app.bundleID ?? "macOS"),
                            trailing: "\(app.pid)",
                            appImage: AppIconResolver.icon(for: app),
                            fallbackSymbol: icon(for: app.place),
                            dotColor: nil
                        )
                        .tag(app.id)
                    }
                }
            }

            if !model.filteredInbox.isEmpty {
                Section("Phone Inbox") {
                    ForEach(model.filteredInbox, id: \.offset) { index, item in
                        SidebarTargetRow(
                            title: item.app ?? "Device",
                            subtitle: item.top,
                            trailing: "\(item.mainGapMS) ms",
                            appImage: nil,
                            fallbackSymbol: nil,
                            dotColor: dotColor(for: item.kind)
                        )
                        .tag("inbox:\(index)")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $model.sidebarQuery, placement: .sidebar, prompt: "Filter apps or pid")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sidebarFooter
        }
    }

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            Button {
                model.toggleInbox()
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.inboxListening ? ProbeTheme.ok : ProbeTheme.inkMuted.opacity(0.55))
                        .frame(width: 6, height: 6)
                    Text(model.inboxListening ? "Inbox live" : "Phone Inbox")
                        .font(ProbeFont.ui(11.5))
                        .foregroundStyle(model.inboxListening ? ProbeTheme.ink : ProbeTheme.inkSecondary)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .help(model.inboxListening ? "Stop Phone Inbox (:9481)" : "Start Phone Inbox (:9481)")

            Menu {
                Button("Import MetricKit / Hang JSON…") { model.importMetricKitFile() }
                Button("Pull Android ExitInfo ANRs") { model.pullAndroidExitInfo() }
                Divider()
                Button("Busy sample") { model.loadShowcase(.busy) }
                Button("Blocked sample") { model.loadShowcase(.blocked) }
                Button("Responsive sample") { model.loadShowcase(.responsive) }
                Divider()
                Button("About Hangprobe…") {
                    model.showAboutSheet = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(ProbeFont.ui(11, weight: .semibold))
                    .foregroundStyle(ProbeTheme.inkMuted)
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Import, samples, about")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ProbeTheme.canvas.opacity(0.001))
        .overlay(alignment: .top) {
            Rectangle().fill(ProbeTheme.hairlineSoft).frame(height: 1)
        }
    }

    // MARK: - Detail

    private var detail: some View {
        Group {
            if let report = model.report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let error = model.error {
                            errorBanner(error)
                        }
                        VerdictHeroCard(report: report, onCopySymbol: model.copySymbol)
                        postHangActions(for: report)
                        StackInspectorView(
                            report: report,
                            earlier: model.earlier,
                            history: model.appHistory,
                            tab: $model.inspectorTab,
                            filter: $model.stackFilter,
                            leafFirst: $model.leafFirst,
                            onCopySymbol: model.copySymbol,
                            onSelectHistory: model.selectHistoryReport
                        )
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(ProbeTheme.canvas)
            } else if let error = model.error {
                ScrollView {
                    errorBanner(error)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                emptyWorkspace
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ProbeTheme.canvas)
            }
        }
        .navigationTitle(detailTitle)
        .navigationSubtitle(model.status)
    }

    private func postHangActions(for report: HangReport) -> some View {
        let culprit = Symbolicator.leadingAppFrame(stack: report.stack, app: report.app ?? "")
            ?? report.stack.last
            ?? report.top

        return HStack(spacing: 12) {
            Button("Copy culprit") {
                model.copySymbol(culprit)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(report.hung ? "Probe again" : "Probe") {
                model.probe()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.running || model.selected == nil)
            .keyboardShortcut("r", modifiers: [.command])

            if report.hung {
                Button("Copy report") {
                    model.copyReport()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            if model.earlier != nil {
                Button("Show diff") {
                    model.inspectorTab = .history
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            Spacer(minLength: 0)
        }
    }

    private var detailTitle: String {
        if let app = model.selected?.app {
            return app
        }
        if let app = model.report?.app {
            return app
        }
        return "Hangprobe"
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ProbeTheme.blocked)
            Text(error)
                .font(ProbeFont.ui(13))
                .foregroundStyle(ProbeTheme.ink)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button("Dismiss") {
                model.dismissError()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(12)
        .background(ProbeTheme.blocked.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(ProbeTheme.blocked.opacity(0.22), lineWidth: 1)
        )
    }

    private var emptyWorkspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer(minLength: 0)

            Text("Sample a frozen main thread")
                .font(ProbeFont.ui(22, weight: .semibold))
                .foregroundStyle(ProbeTheme.ink)

            Text("Pick a Simulator, Mac, or Android target in the sidebar, then press ⌘R. Nothing links into your app.")
                .font(ProbeFont.ui(13.5))
                .foregroundStyle(ProbeTheme.inkSecondary)
                .frame(maxWidth: 420, alignment: .leading)

            if model.selected != nil {
                Button {
                    model.probe()
                } label: {
                    Label("Probe \(model.selected?.app ?? "target")", systemImage: "waveform.path.ecg")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.running)
                .padding(.top, 2)
            }

            HStack(spacing: 16) {
                Button("Busy sample") { model.loadShowcase(.busy) }
                Button("Blocked sample") { model.loadShowcase(.blocked) }
                Button("Responsive sample") { model.loadShowcase(.responsive) }
            }
            .buttonStyle(.link)
            .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            sampleConfigMenu

            if model.running {
                ProgressView()
                    .controlSize(.small)
                    .help(model.runningLabel)
            }

            Button {
                model.probe()
            } label: {
                Label("Probe", systemImage: "waveform.path.ecg")
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(model.running || model.selected == nil)
            .help("Sample the selected target (⌘R)")

            Button("Watch") {
                model.watch()
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(model.running || model.selected == nil)
            .help("Sample until the first hang (⇧⌘W)")

            if model.report != nil {
                exportMenu
            }

            Menu {
                Button("Reload Targets") { model.reload() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("10-second Worst Pass") { model.worst() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(model.running || model.selected == nil)
                Divider()
                Button("Appearance: \(model.appearance.rawValue)") { cycleAppearance() }
                Button("About Hangprobe…") {
                    model.showAboutSheet = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help("More actions")
        }
    }

    private var sampleConfigMenu: some View {
        Menu {
            Section("Duration") {
                ForEach([1, 2, 3], id: \.self) { sec in
                    Button {
                        model.seconds = sec
                    } label: {
                        if model.seconds == sec {
                            Label("\(sec)s", systemImage: "checkmark")
                        } else {
                            Text("\(sec)s")
                        }
                    }
                }
            }
            Section("Hang floor") {
                ForEach([100, 250, 500], id: \.self) { ms in
                    Button {
                        model.threshold = ms
                    } label: {
                        if model.threshold == ms {
                            Label("\(ms) ms\(ms == 250 ? " · Apple" : "")", systemImage: "checkmark")
                        } else {
                            Text("\(ms) ms\(ms == 250 ? " · Apple" : "")")
                        }
                    }
                }
            }
        } label: {
            Text("\(model.seconds)s · \(model.threshold) ms")
                .font(ProbeFont.uiDigits(12))
        }
        .help("Sample duration and hang floor")
    }

    private var exportMenu: some View {
        Menu {
            Button("Copy Markdown") { model.copyReport() }
            Button("Copy JSON") { model.copyJSONReport() }
            Divider()
            Button("Save Markdown…") { model.exportMarkdownFile() }
            Button("Save JSON…") { model.exportReportFile() }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .help("Copy or save the hang report")
    }

    // MARK: - Helpers

    private func cycleAppearance() {
        let all = AppearanceMode.allCases
        if let idx = all.firstIndex(of: model.appearance) {
            model.appearance = all[(idx + 1) % all.count]
        }
    }

    private var sections: [AppSection] {
        let order: [(ProbePlace, String)] = [
            (.simulator, "iOS Simulator"),
            (.mac, "macOS"),
            (.android, "Android adb"),
        ]
        let list = model.filteredApps
        return order.compactMap { place, title in
            let matches = list.filter { $0.place == place }
            return matches.isEmpty ? nil : AppSection(title: title, apps: matches)
        }
    }

    private func icon(for place: ProbePlace) -> String {
        switch place {
        case .simulator: return "iphone"
        case .mac: return "macwindow"
        case .android: return "apple.terminal"
        case .ios: return "iphone"
        }
    }

    private func dotColor(for kind: HangKind) -> Color {
        switch kind {
        case .responsive: return ProbeTheme.ok
        case .busy: return ProbeTheme.busy
        case .blocked: return ProbeTheme.blocked
        }
    }
}

struct SidebarTargetRow: View {
    var title: String
    var subtitle: String
    var trailing: String
    var appImage: NSImage?
    var fallbackSymbol: String?
    var dotColor: Color?

    var body: some View {
        HStack(spacing: 8) {
            if let appImage {
                Image(nsImage: appImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
            } else if let dotColor {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                    .frame(width: 20, height: 20)
            } else if let fallbackSymbol {
                Image(systemName: fallbackSymbol)
                    .font(ProbeFont.ui(11, weight: .medium))
                    .foregroundStyle(ProbeTheme.inkMuted)
                    .frame(width: 20, height: 20)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(ProbeFont.ui(12.5, weight: .medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(ProbeFont.ui(10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(trailing)
                .font(ProbeFont.uiDigits(10.5))
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
    }
}

struct AppSection: Identifiable {
    var title: String
    var apps: [RunningApp]
    var id: String { title }
}
