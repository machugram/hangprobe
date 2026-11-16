import SwiftUI

@main
struct HangprobeApp: App {
    init() {
        FontRegistration.registerBundledFontsIfNeeded()
        Task { @MainActor in
            AppIconResolver.applyBundledDockIconIfAvailable()
        }
    }

    var body: some Scene {
        WindowGroup("Hangprobe") {
            ProbeWindow()
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1100, height: 700)
    }
}
