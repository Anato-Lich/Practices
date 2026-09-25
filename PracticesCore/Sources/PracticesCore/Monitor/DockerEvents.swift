import Foundation

/// Something about a container worth telling the user.
public struct ContainerIncident: Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        case crashed            // die with a non-zero, non-signal-stop exit code
        case outOfMemory        // oom
        case unhealthy          // health_status: unhealthy
        case restartLoop        // several dies in a short window
    }

    public let kind: Kind
    public let containerID: String
    public let name: String
    public let composeProject: String?
    public let exitCode: Int?
    public let date: Date
}

/// Raw event from `docker events --format '{{json .}}'`.
struct DockerEvent: Decodable {
    struct Actor: Decodable {
        let ID: String
        let Attributes: [String: String]?
    }
    let `Type`: String?
    let Action: String
    let Actor: Actor
    let time: Int?
}

/// Turns the container event stream into incidents (DECISIONS 8, 9).
public struct IncidentDetector: Sendable {

    /// Exit codes of a normal stop: 0, SIGINT (130, Ctrl-C), SIGTERM (143, docker stop).
    public static let quietExitCodes: Set<Int> = [0, 130, 143]
    public static let loopWindow: TimeInterval = 300
    public static let loopCount = 3

    private var recentDies: [String: [Date]] = [:]
    /// Containers the app itself is stopping; their exit is expected.
    private var expected: [String: Date] = [:]

    public init() {}

    public mutating func expectStop(of id: String, at date: Date = Date()) {
        expected[id] = date
    }

    mutating func consume(_ event: DockerEvent) -> [ContainerIncident] {
        guard event.Type == nil || event.Type == "container" else { return [] }
        let attributes = event.Actor.Attributes ?? [:]
        let id = event.Actor.ID
        let date = event.time.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
        func incident(_ kind: ContainerIncident.Kind, exit: Int? = nil) -> ContainerIncident {
            ContainerIncident(
                kind: kind, containerID: id, name: attributes["name"] ?? String(id.prefix(12)),
                composeProject: attributes["com.docker.compose.project"], exitCode: exit, date: date)
        }

        switch event.Action {
        case "oom":
            return [incident(.outOfMemory)]
        case "health_status: unhealthy":
            return [incident(.unhealthy)]
        case "die":
            let code = attributes["exitCode"].flatMap(Int.init)
            if let since = expected[id], date.timeIntervalSince(since) < 60 {
                expected[id] = nil
                return []
            }
            var dies = (recentDies[id] ?? []).filter { date.timeIntervalSince($0) < Self.loopWindow }
            dies.append(date)
            recentDies[id] = dies
            if dies.count == Self.loopCount {
                return [incident(.restartLoop, exit: code)]
            }
            // Only the first die of a burst is reported as a crash; a burst that reaches
            // loopCount is reported once more as a loop, and then stays quiet.
            if dies.count > 1 { return [] }
            if let code, !Self.quietExitCodes.contains(code) {
                return [incident(.crashed, exit: code)]
            }
            return []
        default:
            return []
        }
    }
}

public enum DockerEvents {

    /// Container incidents as they happen. The stream reconnects with a back-off when the
    /// daemon goes away (Docker Desktop restarting, switching to OrbStack) and yields nothing
    /// while it is down. Expected stops are registered through `expectStop`.
    public static func incidents(expectStop: AsyncStream<String>? = nil) -> AsyncStream<ContainerIncident> {
        AsyncStream { continuation in
            let task = Task {
                let detector = DetectorBox()
                if let expectStop {
                    Task { for await id in expectStop { await detector.expect(id) } }
                }
                var delay: UInt64 = 2
                while !Task.isCancelled {
                    let started = Date()
                    for await line in lines(["events", "--filter", "type=container", "--format", "{{json .}}"]) {
                        guard let event = try? JSONDecoder().decode(DockerEvent.self, from: Data(line.utf8))
                        else { continue }
                        for incident in await detector.consume(event) { continuation.yield(incident) }
                    }
                    if Date().timeIntervalSince(started) > 30 { delay = 2 }
                    try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    delay = min(delay * 2, 60)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private actor DetectorBox {
        var detector = IncidentDetector()
        func expect(_ id: String) { detector.expectStop(of: id) }
        func consume(_ event: DockerEvent) -> [ContainerIncident] { detector.consume(event) }
    }

    /// Lines a long-running docker command prints, until it exits or the consumer stops.
    static func lines(_ arguments: [String]) -> AsyncStream<String> {
        AsyncStream { continuation in
            guard let path = Shell.locate("docker") else { continuation.finish(); return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.environment = Shell.environment
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            let buffer = LineBuffer()
            out.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                for line in buffer.append(data) { continuation.yield(line) }
            }
            process.terminationHandler = { _ in continuation.finish() }
            continuation.onTermination = { _ in if process.isRunning { process.terminate() } }
            do { try process.run() } catch { continuation.finish() }
        }
    }
}

final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    func append(_ data: Data) -> [String] {
        lock.withLock {
            pending.append(data)
            var lines: [String] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
            return lines
        }
    }
}
