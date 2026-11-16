import HangprobeCore
import SwiftUI

struct AboutSheetView: View {
    @Bindable var model: ProbeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Hangprobe")
                        .font(ProbeFont.ui(17, weight: .semibold))
                        .foregroundStyle(ProbeTheme.ink)
                    Text("MIT open source · desk hang tool for Mac, Simulator, and Android")
                        .font(ProbeFont.ui(12.5))
                        .foregroundStyle(ProbeTheme.inkMuted)
                }
                Spacer()
                Text("v\(HangprobeVersion.marketing)")
                    .font(ProbeFont.ui(12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(ProbeTheme.focus.opacity(0.16), in: Capsule())
                    .foregroundStyle(ProbeTheme.focusSoft)
            }

            VStack(alignment: .leading, spacing: 8) {
                featureLine("Live probe, Watch, and 10s Worst pass")
                featureLine("Hotspots, Diff & Trend, App Focus folding")
                featureLine("MetricKit / adb ExitInfo imports")
                featureLine("Phone Inbox (:9481) and CI gate")
                featureLine("Markdown & JSON export · MCP probe_hang")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ProbeTheme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(ProbeTheme.hairlineSoft, lineWidth: 1)
            )

            Text("MIT · clone, build with SwiftPM, ship patches.")
                .font(ProbeFont.ui(12.5))
                .foregroundStyle(ProbeTheme.inkSecondary)

            HStack {
                Spacer()
                Button("Done") {
                    model.showAboutSheet = false
                }
                .buttonStyle(.plain)
                .font(ProbeFont.ui(12.5, weight: .medium))
                .foregroundStyle(ProbeTheme.inkSecondary)
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(ProbeTheme.surface)
    }

    private func featureLine(_ text: String) -> some View {
        Text("· \(text)")
            .font(ProbeFont.ui(12.5))
            .foregroundStyle(ProbeTheme.inkSecondary)
    }
}
