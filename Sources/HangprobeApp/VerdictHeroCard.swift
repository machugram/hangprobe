import HangprobeCore
import SwiftUI

/// Flush instrument header — gap, kind, bar, culprit. No card chrome.
struct VerdictHeroCard: View {
    var report: HangReport
    var onCopySymbol: (String) -> Void

    var body: some View {
        let sig = signal
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(report.gapAtLeast ? "≥ " : "")\(report.mainGapMS)")
                        .font(ProbeFont.display(34, weight: .medium))
                        .foregroundStyle(ProbeTheme.ink)
                    Text("ms")
                        .font(ProbeFont.ui(16, weight: .regular))
                        .foregroundStyle(ProbeTheme.inkMuted)
                }

                Text(report.kind.rawValue)
                    .font(ProbeFont.ui(12, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(sig.fill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .foregroundStyle(sig.soft)

                Spacer(minLength: 8)

                Text(sampleMeta)
                    .font(ProbeFont.uiDigits(11.5))
                    .foregroundStyle(ProbeTheme.inkMuted)
                    .lineLimit(1)
            }

            GapBar(report: report)

            HStack(spacing: 12) {
                metaPair(label: "Busy", value: "\(report.busyMS) ms", active: report.busyMS > 0, color: ProbeTheme.busy)
                metaPair(label: "Blocked", value: "\(report.blockedMS) ms", active: report.blockedMS > 0, color: ProbeTheme.blocked)
                metaPair(
                    label: "Wait",
                    value: "\(report.eventWaitMS) ms",
                    active: report.eventWaitMS > 0 || !report.hung,
                    color: ProbeTheme.ok
                )
                Spacer(minLength: 8)
            }

            culpritRow

            Text(verdictNote)
                .font(ProbeFont.ui(12.5))
                .foregroundStyle(ProbeTheme.inkSecondary)
                .lineLimit(2)
        }
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
    }

    private var sampleMeta: String {
        "\(report.samples) samples · \(report.windowMS) ms · floor \(report.thresholdMS) ms"
    }

    private var culpritRow: some View {
        let appFrame = Symbolicator.leadingAppFrame(stack: report.stack, app: report.app ?? "")
        let raw = appFrame ?? report.stack.last ?? report.top
        let (symbol, module) = splitSymbol(raw)
        let isApp = appFrame != nil

        return HStack(spacing: 8) {
            Text(isApp ? "CULPRIT" : "LEAF")
                .font(ProbeFont.ui(10, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(ProbeTheme.inkMuted)
                .frame(width: 56, alignment: .leading)

            Text(symbol)
                .font(ProbeFont.mono(12.5, weight: .medium))
                .foregroundStyle(isApp ? ProbeTheme.brand : ProbeTheme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer(minLength: 6)

            if let module {
                Text(module)
                    .font(ProbeFont.ui(11.5))
                    .foregroundStyle(ProbeTheme.inkMuted)
                    .lineLimit(1)
            }

            Button("Copy") {
                onCopySymbol(raw)
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .foregroundStyle(ProbeTheme.inkSecondary)
            .accessibilityLabel("Copy culprit frame")
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(ProbeTheme.hairlineSoft)
                .frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ProbeTheme.hairlineSoft)
                .frame(height: 1)
        }
    }

    private func metaPair(label: String, value: String, active: Bool, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(active ? color : ProbeTheme.hairline)
                .frame(width: 6, height: 6)
            Text(label)
                .font(ProbeFont.ui(11.5))
                .foregroundStyle(ProbeTheme.inkMuted)
            Text(value)
                .font(ProbeFont.uiDigits(11.5, weight: .medium))
                .foregroundStyle(active ? ProbeTheme.ink : ProbeTheme.inkMuted)
        }
        .fixedSize()
    }

    private var verdictNote: String {
        if let hint = FrameInspector.contentionSummary(for: report) {
            return hint
        }
        if let note = report.note {
            return note
        }
        return "Main thread stayed parked inside the UI event loop."
    }

    private func splitSymbol(_ raw: String) -> (String, String?) {
        if let range = raw.range(of: " (in ", options: .backwards), raw.hasSuffix(")") {
            let sym = String(raw[..<range.lowerBound])
            let mod = String(raw[range.upperBound..<raw.index(before: raw.endIndex)])
            return (sym, mod)
        }
        return (raw, nil)
    }

    private var signal: (solid: Color, soft: Color, fill: Color, border: Color) {
        switch report.kind {
        case .responsive: return ProbeTheme.signal(for: .responsive)
        case .busy: return ProbeTheme.signal(for: .busy)
        case .blocked: return ProbeTheme.signal(for: .blocked)
        }
    }
}

struct GapBar: View {
    var report: HangReport

    var body: some View {
        let fallbackWait = (!report.hung && report.busyMS == 0 && report.blockedMS == 0)
            ? max(report.windowMS, 1)
            : report.eventWaitMS
        let total = max(report.windowMS, max(report.busyMS + report.blockedMS + fallbackWait, 1))
        let thresholdRatio = min(1.0, max(0.0, CGFloat(report.thresholdMS) / CGFloat(total)))

        GeometryReader { proxy in
            let w = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(ProbeTheme.surfaceSubtle)

                HStack(spacing: 1) {
                    if report.busyMS > 0 {
                        Capsule()
                            .fill(ProbeTheme.busy)
                            .frame(width: max(3, w * CGFloat(report.busyMS) / CGFloat(total)))
                    }
                    if report.blockedMS > 0 {
                        Capsule()
                            .fill(ProbeTheme.blocked)
                            .frame(width: max(3, w * CGFloat(report.blockedMS) / CGFloat(total)))
                    }
                    if fallbackWait > 0 {
                        Capsule()
                            .fill(ProbeTheme.ok.opacity(0.75))
                            .frame(width: max(3, w * CGFloat(fallbackWait) / CGFloat(total)))
                    }
                }

                if thresholdRatio > 0.04 && thresholdRatio < 0.96 {
                    Rectangle()
                        .fill(ProbeTheme.ink.opacity(0.45))
                        .frame(width: 1, height: 10)
                        .offset(x: w * thresholdRatio)
                        .help("Hang floor (\(report.thresholdMS) ms)")
                }
            }
        }
        .frame(height: 5)
        .accessibilityLabel(
            "Busy \(report.busyMS) ms, blocked \(report.blockedMS) ms, event wait \(report.eventWaitMS) ms"
        )
    }
}
