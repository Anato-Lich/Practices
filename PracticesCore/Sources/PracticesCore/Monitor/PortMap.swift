import Foundation

/// One occupied port, attributed to whoever holds it.
public struct PortEntry: Identifiable, Hashable, Sendable, Codable {
    public enum Owner: Hashable, Sendable, Codable {
        case container(Container)
        case process(pid: Int32, command: String)
    }

    public let port: Int
    public let address: String
    public let owner: Owner
    /// Compose project or the `~/Projects/<name>` folder the process runs in.
    public let project: String?
    public let projectDir: String?

    public var id: String {
        switch owner {
        case .container(let c): "\(port)-c-\(c.id)"
        case .process(let pid, _): "\(port)-p-\(pid)"
        }
    }

    public var ownerName: String {
        switch owner {
        case .container(let c): c.name
        case .process(_, let command): command
        }
    }
}

public struct MonitorSnapshot: Sendable, Codable {
    public let date: Date
    public let dockerContext: String?
    /// nil when the daemon did not answer (not running, switching contexts).
    public let containers: [Container]?
    public let dockerError: String?
    public let ports: [PortEntry]

    public var failedContainers: [Container] {
        (containers ?? []).filter { c in
            c.isUnhealthy || c.state == "restarting" || c.state == "dead"
                || (c.exitCode.map { !IncidentDetector.quietExitCodes.contains($0) } ?? false)
        }
    }

    /// Ports held by more than one owner (a process listening next to a published port, or
    /// two processes on different addresses of the same port).
    public var contestedPorts: Set<Int> {
        Set(Dictionary(grouping: ports, by: \.port).filter { $0.value.count > 1 }.keys)
    }
}

public enum Monitor {

    /// Processes that listen on behalf of containers: their sockets are reported through
    /// the container that publishes the port instead.
    static let dockerForwarders: Set<String> = [
        "com.docker.backend", "com.docker.vpnkit", "vpnkit-bridge", "com.docker.v",
        "OrbStack Helper", "OrbStack", "orbstack", "limactl", "gvproxy",
    ]

    public static func projectsRoot() -> String { NSHomeDirectory() + "/Projects" }

    public static func snapshot() async -> MonitorSnapshot {
        async let socketsTask = (try? ListeningPorts.scan()) ?? []
        async let containersTask: Result<[Container], Error> = {
            do { return .success(try await Docker.containers()) } catch { return .failure(error) }
        }()
        async let contextTask = Docker.currentContext()

        let sockets = await socketsTask
        let containersResult = await containersTask
        let context = await contextTask

        let containers = try? containersResult.get()
        var dockerError: String?
        if case .failure(let error) = containersResult { dockerError = String(describing: error) }

        let loose = sockets.filter { !dockerForwarders.contains($0.command) }
        let cwds = await ListeningPorts.workingDirectories(of: Array(Set(loose.map(\.pid))))
        let ports = merge(sockets: sockets, containers: containers ?? [], cwds: cwds)
        return MonitorSnapshot(date: Date(), dockerContext: context, containers: containers,
                               dockerError: dockerError, ports: ports)
    }

    static func merge(sockets: [ListeningSocket], containers: [Container],
                      cwds: [Int32: String], root: String = projectsRoot()) -> [PortEntry] {
        var entries: [PortEntry] = []
        var published = Set<Int>()
        for container in containers where container.isRunning {
            for port in container.ports where port.proto == "tcp" {
                published.insert(port.hostPort)
                entries.append(PortEntry(
                    port: port.hostPort, address: port.hostAddress, owner: .container(container),
                    project: container.composeProject ?? container.name, projectDir: container.workingDir))
            }
        }
        for socket in sockets {
            if dockerForwarders.contains(socket.command) && published.contains(socket.port) { continue }
            let dir = cwds[socket.pid].flatMap { projectDirectory(for: $0, root: root) }
            entries.append(PortEntry(
                port: socket.port, address: socket.address,
                owner: .process(pid: socket.pid, command: socket.command),
                project: dir.map { ($0 as NSString).lastPathComponent }, projectDir: dir))
        }
        return entries.sorted { ($0.port, $0.ownerName) < ($1.port, $1.ownerName) }
    }

    /// `~/Projects/X-Keeper/backend/src` → `~/Projects/X-Keeper`. Anything outside the
    /// projects root (including `/` for daemons) has no project.
    static func projectDirectory(for cwd: String, root: String) -> String? {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard cwd.hasPrefix(prefix) else { return nil }
        guard let name = cwd.dropFirst(prefix.count).split(separator: "/").first else { return nil }
        return prefix + name
    }

    /// Stops a process politely, then forcefully if it is still there after `grace`.
    public static func terminate(pid: Int32, grace: Duration = .seconds(3)) async -> Bool {
        guard Darwin.kill(pid, SIGTERM) == 0 else { return false }
        try? await Task.sleep(for: grace)
        if Darwin.kill(pid, 0) == 0 { _ = Darwin.kill(pid, SIGKILL) }
        return true
    }
}
