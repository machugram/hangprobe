import AppKit
import HangprobeCore
import SwiftUI

/// Handles ONLY the Dock miniaturize tile (`⌘M`) and Dock `ms` hang badge,
/// leaving native macOS `NavigationSplitView` titlebar & toolbar chrome untouched.
@MainActor
final class WindowChromeCoordinator: NSObject {
    private weak var observedWindow: NSWindow?
    var latestReport: HangReport? {
        didSet { updateDockBadgeIfNeeded() }
    }

    func attach(to window: NSWindow) {
        guard observedWindow !== window else { return }
        observedWindow = window

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillMiniaturize(_:)),
            name: NSWindow.willMiniaturizeNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidDeminiaturize(_:)),
            name: NSWindow.didDeminiaturizeNotification,
            object: window
        )
    }

    @objc private func windowWillMiniaturize(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        let tileView = NSHostingView(rootView: MiniaturizedDockTileView(report: latestReport))
        tileView.frame = NSRect(x: 0, y: 0, width: 128, height: 128)
        window.dockTile.contentView = tileView
        window.dockTile.display()
    }

    @objc private func windowDidDeminiaturize(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        window.dockTile.contentView = nil
        window.dockTile.display()
    }

    private func updateDockBadgeIfNeeded() {
        guard let report = latestReport else {
            NSApp.dockTile.badgeLabel = nil
            return
        }
        NSApp.dockTile.badgeLabel = report.hung ? "\(report.mainGapMS)ms" : nil
        if let window = observedWindow, window.isMiniaturized {
            let tileView = NSHostingView(rootView: MiniaturizedDockTileView(report: report))
            tileView.frame = NSRect(x: 0, y: 0, width: 128, height: 128)
            window.dockTile.contentView = tileView
            window.dockTile.display()
        }
    }
}

struct WindowAccessor: NSViewRepresentable {
    var report: HangReport?
    @State private var coordinator = WindowChromeCoordinator()

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                coordinator.attach(to: window)
                coordinator.latestReport = report
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                coordinator.attach(to: window)
            }
            coordinator.latestReport = report
        }
    }
}

private struct MiniaturizedDockTileView: View {
    var report: HangReport?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 2)
                )

            if let report {
                VStack(spacing: 6) {
                    Circle()
                        .fill(statusColor(report.kind))
                        .frame(width: 16, height: 16)
                    Text("\(report.mainGapMS)")
                        .font(ProbeFont.uiDigits(34, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("ms · \(report.kind.rawValue)")
                        .font(ProbeFont.ui(12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.75))
                }
            } else {
                BrandMarkView(size: 92)
            }
        }
        .padding(8)
        .frame(width: 128, height: 128)
    }

    private func statusColor(_ kind: HangKind) -> Color {
        switch kind {
        case .responsive: return Color(red: 0.49, green: 0.77, blue: 0.48)
        case .busy: return Color(red: 0.86, green: 0.62, blue: 0.37)
        case .blocked: return Color(red: 0.88, green: 0.42, blue: 0.46)
        }
    }
}
