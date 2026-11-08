import Foundation

/// Runs the command-line tools the catalogue relies on (`git`, `gh`, `glab`, `uv`).
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
            // Blocking reads on a GCD thread, not the cooperative pool.
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.environment = environment
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                let stdin = input.map { _ in Pipe() }
                process.standardInput = stdin ?? FileHandle.nullDevice
                do { try process.run() } catch { continuation.resume(throwing: error); return }
                if let stdin, let input {
                    // Written off this thread: a large input would block on a full pipe.
                    DispatchQueue.global().async {
                        stdin.fileHandleForWriting.write(input)
                        try? stdin.fileHandleForWriting.close()
                    }
                }
                // Both pipes are read to EOF before the exit is looked at: a full pipe would block
                // the tool, and a readabilityHandler chunk still in flight at termination was lost.
                let collector = OutputCollector()
                let stderrDone = DispatchGroup()
                DispatchQueue.global().async(group: stderrDone) {
                    collector.append(err: err.fileHandleForReading.readDataToEndOfFile())
                }
                collector.append(out: out.fileHandleForReading.readDataToEndOfFile())
                stderrDone.wait()
                process.waitUntilExit()
                let (stdout, stderr) = collector.strings
                if allowedStatuses.contains(process.terminationStatus) {
                    continuation.resume(returning: stdout)
                } else {
                    continuation.resume(throwing: Failure(tool: tool, status: process.terminationStatus, stderr: stderr))
                }
            }
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
