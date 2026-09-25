import Foundation

/// A host port a container publishes: `0.0.0.0:58123->8123/tcp`.
public struct PublishedPort: Hashable, Sendable, Codable {
    public let hostAddress: String
    public let hostPort: Int
    public let containerPort: Int
    public let proto: String
}

public struct Container: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let name: String
    public let image: String
    public let state: String            // running, exited, restarting, paused, created, dead
    public let status: String           // "Up 2 hours (healthy)", "Exited (137) 3 minutes ago"
    public let ports: [PublishedPort]
    public let composeProject: String?
    public let composeService: String?
    public let workingDir: String?      // compose project directory

    public var isRunning: Bool { state == "running" }
    public var isUnhealthy: Bool { status.contains("(unhealthy)") }

    /// Exit code parsed from the status line of a stopped container.
    public var exitCode: Int? {
        guard state == "exited", let open = status.firstIndex(of: "("),
              let close = status[open...].firstIndex(of: ")") else { return nil }
        return Int(status[status.index(after: open)..<close])
    }

    /// The name compose containers answer to under OrbStack: `service.project.orb.local`.
    public var orbDomain: String {
        if let service = composeService, let project = composeProject {
            return "\(service).\(project).orb.local"
        }
        return "\(name).orb.local"
    }
}

public enum Docker {

    /// Output template for `docker ps`. Labels are pulled one by one with `.Label`, because
    /// the combined `.Labels` string is comma-joined and compose working dirs may hold commas.
    static let psFormat = #"{"id":{{json .ID}},"name":{{json .Names}},"image":{{json .Image}},"state":{{json .State}},"status":{{json .Status}},"ports":{{json .Ports}},"project":{{json (.Label "com.docker.compose.project")}},"service":{{json (.Label "com.docker.compose.service")}},"workdir":{{json (.Label "com.docker.compose.project.working_dir")}}}"#

    private struct Row: Decodable {
        let id, name, image, state, status, ports, project, service, workdir: String
    }

    public static func containers(includeStopped: Bool = true) async throws -> [Container] {
        var args = ["ps", "--no-trunc", "--format", psFormat]
        if includeStopped { args.insert("-a", at: 1) }
        return parse(psOutput: try await Shell.run("docker", args))
    }

    static func parse(psOutput output: String) -> [Container] {
        let decoder = JSONDecoder()
        return output.split(separator: "\n").compactMap { line in
            guard let row = try? decoder.decode(Row.self, from: Data(line.utf8)) else { return nil }
            return Container(
                id: row.id, name: row.name, image: row.image, state: row.state, status: row.status,
                ports: parse(ports: row.ports),
                composeProject: row.project.nilIfEmpty, composeService: row.service.nilIfEmpty,
                workingDir: row.workdir.nilIfEmpty)
        }
    }

    /// Parses the `Ports` column. Unpublished ports (`48210/tcp`) are dropped; the IPv4 and
    /// IPv6 copies of one mapping collapse into one; ranges expand pairwise.
    static func parse(ports column: String) -> [PublishedPort] {
        var result: [PublishedPort] = []
        for item in column.split(separator: ",") {
            let entry = item.trimmingCharacters(in: .whitespaces)
            guard let arrow = entry.range(of: "->") else { continue }
            let host = entry[..<arrow.lowerBound]
            let target = entry[arrow.upperBound...]
            guard let colon = host.lastIndex(of: ":") else { continue }
            let address = String(host[..<colon])
            let slash = target.firstIndex(of: "/") ?? target.endIndex
            let proto = slash < target.endIndex ? String(target[target.index(after: slash)...]) : "tcp"
            let hostPorts = range(host[host.index(after: colon)...])
            let containerPorts = range(target[..<slash])
            for (i, hostPort) in hostPorts.enumerated() {
                let containerPort = i < containerPorts.count ? containerPorts[i] : containerPorts.last ?? hostPort
                let port = PublishedPort(hostAddress: address, hostPort: hostPort,
                                         containerPort: containerPort, proto: proto)
                if !result.contains(where: { $0.hostPort == hostPort && $0.proto == proto }) {
                    result.append(port)
                }
            }
        }
        return result
    }

    private static func range(_ text: Substring) -> [Int] {
        let bounds = text.split(separator: "-").compactMap { Int($0) }
        guard let first = bounds.first else { return [] }
        let last = bounds.count > 1 ? bounds[1] : first
        return last >= first ? Array(first...last) : [first]
    }

    /// Name of the active context: `orbstack`, `desktop-linux`, `default`.
    public static func currentContext() async -> String? {
        (try? await Shell.run("docker", ["context", "show"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public static func stop(_ id: String) async throws {
        _ = try await Shell.run("docker", ["stop", id])
    }

    public static func kill(_ id: String) async throws {
        _ = try await Shell.run("docker", ["kill", id])
    }

    public static func start(_ id: String) async throws {
        _ = try await Shell.run("docker", ["start", id])
    }

    public static func remove(_ id: String) async throws {
        _ = try await Shell.run("docker", ["rm", id])
    }

    /// Last lines of a container's log, stdout and stderr interleaved.
    public static func logs(_ id: String, tail: Int = 200) async throws -> String {
        guard let path = Shell.locate("docker") else { throw Shell.NotFound(tool: "docker") }
        // `docker logs` writes the container's stderr to its own stderr; merge through sh.
        return try await Shell.run("/bin/sh", ["-c", "\"$0\" logs --tail \(tail) --timestamps \"$1\" 2>&1", path, id])
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
