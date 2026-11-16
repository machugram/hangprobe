import HangprobeCore
import SwiftUI

struct StackInspectorView: View {
    var report: HangReport
    var earlier: HangReport?
    var history: [HangReport]
    @Binding var tab: InspectorTab
    @Binding var filter: String
    @Binding var leafFirst: Bool
    var onCopySymbol: (String) -> Void
    var onSelectHistory: (HangReport, Int) -> Void

    @State private var expandedGroups: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            inspectorBar

            Rectangle()
                .fill(ProbeTheme.hairlineSoft)
                .frame(height: 1)

            switch tab {
            case .appFocus:
                appFocusPane
            case .fullStack:
                fullStackPane
            case .hotspots:
                hotspotsPane
            case .history:
                historyAndDiffPane
            }
        }
    }

    private var inspectorBar: some View {
        HStack(spacing: 10) {
            Picker("Inspector", selection: $tab) {
                ForEach(InspectorTab.allCases) { item in
                    Text(item.rawValue)
                        .tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 460)

            Spacer(minLength: 8)

            if tab == .appFocus || tab == .fullStack {
                Button {
                    leafFirst.toggle()
                } label: {
                    Text(leafFirst ? "Leaf first" : "Root first")
                        .font(ProbeFont.ui(11.5))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(ProbeTheme.inkSecondary)
                .help("Reverse stack order")

                TextField("Filter…", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .font(ProbeFont.ui(12))
                    .frame(width: 140)
            }
        }
    }


    private var appFocusPane: some View {
        let rawGroups = FrameInspector.grouped(stack: report.stack, app: report.app, bundleID: report.bundleID)
        let groups = leafFirst ? Array(rawGroups.reversed()) : rawGroups
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return VStack(alignment: .leading, spacing: 1) {
            ForEach(groups) { group in
                switch group {
                case .focus(let frame):
                    if query.isEmpty || frame.raw.lowercased().contains(query) {
                        FrameRow(frame: frame, isLeaf: frame.index == report.stack.count - 1, onCopy: onCopySymbol)
                    }
                case .collapsedSystem(let id, let frames):
                    let ordered = leafFirst ? Array(frames.reversed()) : frames
                    let matching = query.isEmpty ? ordered : ordered.filter { $0.raw.lowercased().contains(query) }
                    if !query.isEmpty {
                        ForEach(matching) { frame in
                            FrameRow(frame: frame, isLeaf: false, onCopy: onCopySymbol)
                        }
                    } else if expandedGroups.contains(id) {
                        Button {
                            expandedGroups.remove(id)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.down")
                                    .font(ProbeFont.ui(9, weight: .semibold))
                                Text("Fold \(frames.count) framework frames")
                                    .font(ProbeFont.ui(11.5))
                            }
                            .foregroundStyle(ProbeTheme.inkMuted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)

                        ForEach(ordered) { frame in
                            FrameRow(frame: frame, isLeaf: false, onCopy: onCopySymbol)
                        }
                    } else {
                        Button {
                            expandedGroups.insert(id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "chevron.right")
                                    .font(ProbeFont.ui(9, weight: .semibold))
                                    .foregroundStyle(ProbeTheme.inkMuted)
                                Text("\(frames.count) system frames")
                                    .font(ProbeFont.ui(12))
                                    .foregroundStyle(ProbeTheme.inkSecondary)
                                Text(moduleSummary(frames))
                                    .font(ProbeFont.ui(11))
                                    .foregroundStyle(ProbeTheme.inkMuted)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var fullStackPane: some View {
        let all = FrameInspector.inspect(stack: report.stack, app: report.app, bundleID: report.bundleID)
        let ordered = leafFirst ? Array(all.reversed()) : all
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let visible = query.isEmpty ? ordered : ordered.filter { $0.raw.lowercased().contains(query) }

        return VStack(alignment: .leading, spacing: 1) {
            if visible.isEmpty {
                Text("No frames match “\(filter)”.")
                    .font(ProbeFont.ui(13))
                    .foregroundStyle(ProbeTheme.inkMuted)
                    .padding(.vertical, 12)
            } else {
                ForEach(visible) { frame in
                    FrameRow(frame: frame, isLeaf: frame.index == report.stack.count - 1, onCopy: onCopySymbol)
                }
            }
        }
    }

    private var hotspotsPane: some View {
        let spots = report.hotspots ?? report.stack.reversed().map {
            FrameHotspot(frame: $0, hits: report.samples, totalSamples: max(report.samples, 1))
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Presence across \(report.samples) main-thread sample\(report.samples == 1 ? "" : "s")")
                .font(ProbeFont.ui(12))
                .foregroundStyle(ProbeTheme.inkMuted)

            ForEach(spots) { spot in
                let isApp = (report.app.map { spot.frame.contains("(in \($0))") || spot.frame.contains($0) } == true)
                HStack(spacing: 10) {
                    Text("\(spot.percent)%")
                        .font(ProbeFont.uiDigits(12, weight: .semibold))
                        .foregroundStyle(isApp ? ProbeTheme.focusSoft : ProbeTheme.ink)
                        .frame(width: 40, alignment: .trailing)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(ProbeTheme.hairlineSoft)
                            Capsule()
                                .fill(isApp ? ProbeTheme.focus : ProbeTheme.inkMuted.opacity(0.55))
                                .frame(width: max(4, geo.size.width * spot.share))
                        }
                    }
                    .frame(width: 72, height: 5)

                    Text(spot.frame)
                        .font(ProbeFont.mono(12, weight: isApp ? .medium : .regular))
                        .foregroundStyle(isApp ? ProbeTheme.ink : ProbeTheme.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var historyAndDiffPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            if history.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Run-over-run gap")
                        .font(ProbeFont.ui(12, weight: .medium))
                        .foregroundStyle(ProbeTheme.inkMuted)
                    TrendSparkStrip(
                        reports: history,
                        selected: report,
                        thresholdMS: report.thresholdMS,
                        onSelect: onSelectHistory
                    )
                }
            }

            if let earlier {
                let diff = ProbeDiff.compare(earlier, report)
                let improved = diff.gapDeltaMS <= 0
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(improved ? ProbeTheme.ok : ProbeTheme.busy)
                            .frame(width: 7, height: 7)
                        Text("Gap \(diff.beforeGapMS) → \(diff.afterGapMS) ms (\(diff.gapDeltaMS > 0 ? "+" : "")\(diff.gapDeltaMS) ms)")
                            .font(ProbeFont.uiDigits(13, weight: .medium))
                            .foregroundStyle(ProbeTheme.ink)
                    }

                    if !diff.framesRemoved.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Left the stack")
                                .font(ProbeFont.ui(11, weight: .semibold))
                                .foregroundStyle(ProbeTheme.okSoft)
                            ForEach(diff.framesRemoved, id: \.self) { frame in
                                Text("−  \(frame)")
                                    .font(ProbeFont.mono(12))
                                    .foregroundStyle(ProbeTheme.inkSecondary)
                            }
                        }
                    }

                    if !diff.framesAdded.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Entered the stack")
                                .font(ProbeFont.ui(11, weight: .semibold))
                                .foregroundStyle(ProbeTheme.busySoft)
                            ForEach(diff.framesAdded, id: \.self) { frame in
                                Text("+  \(frame)")
                                    .font(ProbeFont.mono(12))
                                    .foregroundStyle(ProbeTheme.inkSecondary)
                            }
                        }
                    }
                }
            } else {
                Text("Probe again after a change to compare main_gap_ms and confirm the offending frame left.")
                    .font(ProbeFont.ui(13))
                    .foregroundStyle(ProbeTheme.inkMuted)
            }
        }
    }

    private func moduleSummary(_ frames: [ClassifiedFrame]) -> String {
        var seen: [String] = []
        for mod in frames.compactMap(\.module) where !seen.contains(mod) {
            seen.append(mod)
        }
        return seen.prefix(4).joined(separator: " → ")
    }
}

struct FrameRow: View {
    var frame: ClassifiedFrame
    var isLeaf: Bool
    var onCopy: (String) -> Void

    @State private var hovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(frame.index)")
                .font(ProbeFont.uiDigits(11))
                .foregroundStyle(ProbeTheme.inkMuted)
                .frame(width: 22, alignment: .trailing)

            Text(layerLabel(frame.layer))
                .font(ProbeFont.ui(10, weight: .semibold))
                .foregroundStyle(layerColor)
                .frame(width: 36, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(frame.symbol)
                    .font(ProbeFont.mono(12, weight: (frame.isDeveloperFocus || isLeaf) ? .medium : .regular))
                    .foregroundStyle(symbolColor)
                    .textSelection(.enabled)
                if let hint = frame.hint {
                    Text(hint)
                        .font(ProbeFont.ui(11))
                        .foregroundStyle(ProbeTheme.blockedSoft)
                }
            }

            Spacer(minLength: 8)

            if hovered {
                Button("Copy") {
                    onCopy(frame.raw)
                }
                .font(ProbeFont.ui(11))
                .buttonStyle(.borderless)
                .foregroundStyle(ProbeTheme.inkSecondary)
            } else if let module = frame.module {
                Text(module)
                    .font(ProbeFont.ui(11))
                    .foregroundStyle(frame.layer == .app ? ProbeTheme.focusSoft.opacity(0.85) : ProbeTheme.inkMuted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(rowFill)
        )
        .onHover { hovered = $0 }
    }

    private var layerLabel: (FrameLayer) -> String {
        { layer in
            switch layer {
            case .app: return "App"
            case .lock: return "Lock"
            case .ui: return "UI"
            case .runloop: return "Loop"
            case .system: return "Sys"
            case .kernel: return "Kern"
            }
        }
    }

    private var layerColor: Color {
        switch frame.layer {
        case .app: return ProbeTheme.focusSoft
        case .lock: return ProbeTheme.blockedSoft
        default: return ProbeTheme.inkMuted
        }
    }

    private var symbolColor: Color {
        if frame.layer == .app || frame.layer == .lock || isLeaf {
            return ProbeTheme.ink
        }
        return ProbeTheme.inkSecondary
    }

    private var rowFill: Color {
        if hovered { return ProbeTheme.surfaceSubtle.opacity(0.85) }
        switch frame.layer {
        case .app: return ProbeTheme.focus.opacity(0.06)
        case .lock: return ProbeTheme.blocked.opacity(0.06)
        default: return Color.clear
        }
    }
}

struct TrendSparkStrip: View {
    var reports: [HangReport]
    var selected: HangReport
    var thresholdMS: Int
    var onSelect: (HangReport, Int) -> Void

    var body: some View {
        let maxGap = max(reports.map(\.mainGapMS).max() ?? thresholdMS, thresholdMS, 100)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(reports.enumerated()), id: \.offset) { index, item in
                let ratio = CGFloat(item.mainGapMS) / CGFloat(maxGap)
                let isCurrent = item == selected
                Button {
                    onSelect(item, index)
                } label: {
                    VStack(spacing: 4) {
                        Text("\(item.mainGapMS)")
                            .font(ProbeFont.uiDigits(10.5, weight: isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent ? ProbeTheme.ink : ProbeTheme.inkMuted)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(barColor(for: item))
                            .frame(width: 22, height: max(6, 56 * ratio))
                            .overlay(
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .strokeBorder(isCurrent ? ProbeTheme.ink.opacity(0.55) : Color.clear, lineWidth: 1)
                            )
                        Text("#\(index + 1)")
                            .font(ProbeFont.uiDigits(10))
                            .foregroundStyle(ProbeTheme.inkMuted)
                    }
                }
                .buttonStyle(.plain)
                .help("\(item.kind.rawValue) · \(item.mainGapMS) ms · \(item.top)")
            }
            Spacer()
        }
        .frame(height: 88, alignment: .bottom)
    }

    private func barColor(for report: HangReport) -> Color {
        switch report.kind {
        case .responsive: return ProbeTheme.ok.opacity(0.82)
        case .busy: return ProbeTheme.busy
        case .blocked: return ProbeTheme.blocked
        }
    }
}
