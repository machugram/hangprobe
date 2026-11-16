import Foundation

private final class PipeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        storage.append(data)
        lock.unlock()
    }
    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

public enum Shell {
    public struct Result: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    public static func run(_ arguments: [String], timeout: TimeInterval, input: Data? = nil) throws -> Result {
        guard let launch = arguments.first else { throw ProbeError("Missing command.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch)
        process.arguments = Array(arguments.dropFirst())
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let stdoutBox = PipeBox()
        let stderrBox = PipeBox()
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            stdoutBox.append(chunk)
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            stderrBox.append(chunk)
        }
        if let input {
            let pipe = Pipe()
            process.standardInput = pipe
            try process.run()
            pipe.fileHandleForWriting.write(input)
            try? pipe.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
            try process.run()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            throw ProbeError("\(URL(fileURLWithPath: launch).lastPathComponent) did not finish.")
        }
        process.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        stdoutBox.append(out.fileHandleForReading.readDataToEndOfFile())
        stderrBox.append(err.fileHandleForReading.readDataToEndOfFile())
        let stdout = String(data: stdoutBox.data, encoding: .utf8) ?? ""
        let stderr = String(data: stderrBox.data, encoding: .utf8) ?? ""
        return Result(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

public enum Sampler {
    public static func sample(pid: Int32, seconds: Int) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hangprobe-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let result: Shell.Result
        do {
            result = try Shell.run(
                ["/usr/bin/sample", String(pid), String(seconds), "10", "-mayDie", "-file", url.path],
                timeout: TimeInterval(seconds + 60)
            )
        } catch let error as ProbeError {
            throw error
        } catch {
            throw ProbeError("sample did not finish within a minute.")
        }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if !text.contains("com.apple.main-thread") {
            let detail = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            let line = detail.split(separator: "\n").last.map(String.init) ?? "sample recorded no main thread."
            throw ProbeError(String(line.prefix(500)))
        }
        return text
    }
}
