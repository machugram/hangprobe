import AppKit
import HangprobeCore
import SwiftUI

@MainActor
enum AppIconResolver {
    private static var cache: [Int32: NSImage] = [:]

    static func icon(for app: RunningApp) -> NSImage? {
        if let cached = cache[app.pid] {
            return cached
        }
        if app.place == .mac, let running = NSRunningApplication(processIdentifier: app.pid), let img = running.icon {
            cache[app.pid] = img
            return img
        }
        if app.place == .simulator {
            if let sim = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.iphonesimulator" }),
               let img = sim.icon {
                cache[app.pid] = img
                return img
            }
        }
        return nil
    }

    static func applyBundledDockIconIfAvailable() {
        if let bundled = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: bundled) {
            NSApplication.shared.applicationIconImage = image
            return
        }
        let localURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("assets/AppIcon.icns")
        if let image = NSImage(contentsOf: localURL) {
            NSApplication.shared.applicationIconImage = image
        }
    }
}
