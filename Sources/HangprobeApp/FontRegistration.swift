import AppKit
import CoreText
import Foundation

/// Registers bundled IBM Plex faces so `ProbeFont` can resolve them at runtime.
enum FontRegistration {
    private static var didRegister = false

    static func registerBundledFontsIfNeeded() {
        guard !didRegister else { return }
        didRegister = true

        for url in fontURLs() {
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        }
    }

    private static func fontURLs() -> [URL] {
        var urls: [URL] = []
        var seen = Set<String>()

        func append(contentsOf directory: URL?) {
            guard let directory else { return }
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { return }
            for file in files where file.pathExtension.lowercased() == "otf" {
                let key = file.lastPathComponent
                guard seen.insert(key).inserted else { continue }
                urls.append(file)
            }
        }

        // SPM resource bundle (swift build / Bundle.module)
        append(contentsOf: Bundle.module.url(forResource: "Fonts", withExtension: nil))

        // Packaged Hangprobe.app Resources/Fonts
        if let resourceURL = Bundle.main.resourceURL {
            append(contentsOf: resourceURL.appendingPathComponent("Fonts", isDirectory: true))
        }

        // Sibling SPM bundle next to the executable (AppLauncher layout)
        let execDir = Bundle.main.bundleURL.deletingLastPathComponent()
        for bundleName in ["Hangprobe_HangprobeApp.bundle", "HangprobeApp_HangprobeApp.bundle"] {
            let bundleRoot = execDir.appendingPathComponent(bundleName)
            append(contentsOf: bundleRoot.appendingPathComponent("Contents/Resources/Fonts", isDirectory: true))
            append(contentsOf: bundleRoot.appendingPathComponent("Fonts", isDirectory: true))
        }

        // Repo checkout while iterating without a resource bundle
        let cwdFonts = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("assets/fonts", isDirectory: true)
        append(contentsOf: cwdFonts)

        return urls
    }
}
