import Foundation

public enum Symbolicator {
    public static func apply(stack: [String], symbols: [String: String]) -> [String] {
        let keys = symbols.keys.sorted { $0.count > $1.count }
        return stack.map { frame in
            guard let key = keys.first(where: { frame.contains($0) }), let name = symbols[key] else { return frame }
            if let range = frame.range(of: " (in ") {
                return name + frame[range.lowerBound...]
            }
            return frame.replacingOccurrences(of: key, with: name)
        }
    }

    public static func leadingAppFrame(stack: [String], app: String) -> String? {
        guard !app.isEmpty else { return nil }
        return stack.reversed().first { frame in
            frame.contains("(in \(app))") || frame.contains("at \(app)") || frame.contains(app + ".")
        }
    }

    public static func symbolicate(stack: [String], pid: Int32?, app: String) -> [String] {
        guard let pid else { return stack }
        let addresses = stack.compactMap { frame -> String? in
            guard frame.contains("(in \(app))") || frame.contains("???") else { return nil }
            return firstAddress(in: frame)
        }
        guard !addresses.isEmpty else { return stack }
        guard let result = try? Shell.run(["/usr/bin/atos", "-p", String(pid)] + addresses, timeout: 15) else { return stack }
        return mapAtosOutput(stack: stack, addresses: addresses, stdout: result.stdout)
    }

    public static func symbolicateBinary(
        stack: [String],
        binaryOrDSYMPath: String,
        arch: String = "arm64",
        loadAddress: String?,
        app: String
    ) -> [String] {
        guard let binary = resolveMachOBinary(at: binaryOrDSYMPath) else { return stack }
        let addresses = stack.compactMap { frame -> String? in
            guard app.isEmpty || frame.contains("(in \(app))") || frame.contains("???") else { return nil }
            return firstAddress(in: frame)
        }
        guard !addresses.isEmpty else { return stack }
        var args = ["/usr/bin/atos", "-arch", arch, "-o", binary]
        if let loadAddress, !loadAddress.isEmpty {
            args += ["-l", loadAddress]
        }
        args += addresses
        guard let result = try? Shell.run(args, timeout: 15) else { return stack }
        return mapAtosOutput(stack: stack, addresses: addresses, stdout: result.stdout)
    }

    public static func symbolicateReport(
        _ report: HangReport,
        dsymPath: String?,
        ndkSymbolsPath: String? = nil
    ) -> HangReport {
        var next = report
        if let dsymPath, !dsymPath.isEmpty {
            let arch = report.context?.arch ?? "arm64"
            next.stack = symbolicateBinary(
                stack: report.stack,
                binaryOrDSYMPath: dsymPath,
                arch: arch,
                loadAddress: report.context?.loadAddress,
                app: report.app ?? ""
            )
            if let top = next.stack.last {
                next.top = SampleClassifier.leafLabel(top)
            }
        } else if let ndkSymbolsPath, !ndkSymbolsPath.isEmpty, report.place == .android {
            let joined = report.stack.joined(separator: "\n")
            let decoded = ndkStack(trace: joined, symbolPath: ndkSymbolsPath)
            let lines = decoded.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !lines.isEmpty {
                next.stack = Array(lines.suffix(16))
                if let top = next.stack.last { next.top = AndroidTrace.leafLabel(top) }
            }
        }
        return next
    }

    public static func ndkStack(trace: String, symbolPath: String?) -> String {
        guard let symbolPath, !symbolPath.isEmpty else { return trace }
        guard let binary = ndkStackBinary() else { return trace }
        guard let result = try? Shell.run([binary, "-sym", symbolPath], timeout: 20, input: Data(trace.utf8)) else { return trace }
        return result.stdout.isEmpty ? trace : result.stdout
    }

    static func firstAddress(in frame: String) -> String? {
        guard let range = frame.range(of: #"0x[0-9a-fA-F]+"#, options: .regularExpression) else { return nil }
        return String(frame[range])
    }

    private static func mapAtosOutput(stack: [String], addresses: [String], stdout: String) -> [String] {
        let lines = stdout.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        var mapped: [String: String] = [:]
        for (address, line) in zip(addresses, lines) {
            if line.isEmpty || line == address { continue }
            mapped[address] = line.components(separatedBy: " (in ").first?.trimmingCharacters(in: .whitespaces) ?? line
        }
        return apply(stack: stack, symbols: mapped)
    }

    private static func resolveMachOBinary(at path: String) -> String? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue { return path }
        let dwarfDir = URL(fileURLWithPath: path).appendingPathComponent("Contents/Resources/DWARF", isDirectory: true)
        if let files = try? fm.contentsOfDirectory(at: dwarfDir, includingPropertiesForKeys: nil),
           let first = files.first {
            return first.path
        }
        let macosDir = URL(fileURLWithPath: path).appendingPathComponent("Contents/MacOS", isDirectory: true)
        if let files = try? fm.contentsOfDirectory(at: macosDir, includingPropertiesForKeys: nil),
           let first = files.first {
            return first.path
        }
        if let files = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil),
           let first = files.first(where: { $0.pathExtension.isEmpty && fm.isExecutableFile(atPath: $0.path) }) {
            return first.path
        }
        return nil
    }

    private static func ndkStackBinary() -> String? {
        if let path = ProcessInfo.processInfo.environment["NDK_STACK"], FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let which = try? Shell.run(["/usr/bin/env", "which", "ndk-stack"], timeout: 3)
        let path = which?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }
}
