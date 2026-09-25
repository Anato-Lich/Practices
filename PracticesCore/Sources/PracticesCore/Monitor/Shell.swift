import Foundation

/// Runs the command-line tools the monitor is built on (`lsof`, `docker`).
///
/// An app launched from Finder gets a minimal PATH, so tools are looked up in the usual
/// install locations rather than trusted to be on it: Docker Desktop and OrbStack put
/// `docker` in /usr/local/bin, OrbStack also in ~/.orbstack/bin, Homebrew in /opt/homebrew/bin.
public enum Shell {

    public struct Failure: Error, CustomStringConvertible, Sendable {
        public let tool: String
        public let status: Int32
        public let stderr: String
        public var description: String {
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(tool) exited with \(status)" + (message.isEmpty ? "" : ": \(message)")
        }
    }

    public struct NotFound: Error, CustomStringConvertible, Sendable {
        public let tool: String
        public var description: String { "\(tool) not found" }
    }

    static let searchPath: [String] = [
        "/usr/local/bin",
        "/opt/homebrew/bin",
        NSHomeDirectory() + "/.orbstack/bin",
        "/Applications/OrbStack.app/Contents/MacOS/xbin",
        "/Applications/Docker.app/Contents/Resources/bin",
        "/usr/sbin",
        "/usr/bin",
        "/bin",
    ]

    public static func locate(_ tool: String) -> String? {
        if tool.hasPrefix("/") { return tool }
        let fm = FileManager.default
        return searchPath.map { "\($0)/\(tool)" }.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Environment for child processes: the caller's, with the search path prepended so
    /// `docker` finds its credential helpers and compose plugin.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (searchPath + [env["PATH"] ?? ""]).joined(separator: ":")
        return env
    }

    /// Runs `tool` to completion and returns stdout. `allowedStatuses` covers tools that
    /// report "nothing found" through the exit code (lsof exits 1 when nothing listens).
    /// `input` is written to the tool's stdin — the way to hand it a value that must not appear
    /// in its arguments (visible in `ps`) or on disk.
    public static func run(
        _ tool: String, _ arguments: [String], allowedStatuses: Set<Int32> = [0], input: Data? = nil
    ) async throws -> String {
        guard let path = locate(tool) else { throw NotFound(tool: tool) }
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.environment = environment
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            let stdin = input.map { _ in Pipe() }
            process.standardInput = stdin ?? FileHandle.nullDevice

            // Drain both pipes while the process runs; a full pipe buffer would block it.
            let collector = OutputCollector()
            out.fileHandleForReading.readabilityHandler = { collector.append(out: $0.availableData) }
            err.fileHandleForReading.readabilityHandler = { collector.append(err: $0.availableData) }

            process.terminationHandler = { p in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                collector.append(out: out.fileHandleForReading.readDataToEndOfFile())
                collector.append(err: err.fileHandleForReading.readDataToEndOfFile())
                let (stdout, stderr) = collector.strings
                if allowedStatuses.contains(p.terminationStatus) {
                    continuation.resume(returning: stdout)
                } else {
                    continuation.resume(throwing: Failure(
                        tool: tool, status: p.terminationStatus, stderr: stderr))
                }
            }
            do {
                try process.run()
                if let stdin, let input {
                    // Written off the caller's thread: a large input would block on a full pipe.
                    DispatchQueue.global().async {
                        stdin.fileHandleForWriting.write(input)
                        try? stdin.fileHandleForWriting.close()
                    }
                }
            } catch { continuation.resume(throwing: error) }
        }
    }
}

final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data()
    func append(out data: Data) { lock.withLock { out.append(data) } }
    func append(err data: Data) { lock.withLock { err.append(data) } }
    var strings: (String, String) {
        lock.withLock { (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self)) }
    }
}
