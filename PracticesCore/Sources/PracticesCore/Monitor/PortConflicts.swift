import Foundation

/// A port a compose service wants that something else already holds: `docker compose up`
/// would fail with "port is already allocated" (or, for a process bound to one address,
/// start and then quietly lose half its traffic).
public struct PortConflict: Identifiable, Hashable, Sendable, Codable {
    public let claim: PortClaim
    public let holders: [PortEntry]
    /// Host ports the same service is running on right now, when it runs remapped.
    public let runningOn: [Int]

    public var id: String { "\(claim.project)|\(claim.service)|\(claim.hostPort)" }

    /// macOS itself listens on 5000 and 7000 for AirPlay Receiver (ControlCenter).
    public var isAirPlay: Bool {
        holders.contains { if case .process(_, let command) = $0.owner { command == "ControlCenter" } else { false } }
    }
}

/// Two projects that both want one port: harmless until both are started.
public struct PortCollision: Identifiable, Hashable, Sendable, Codable {
    public let hostPort: Int
    public let claims: [PortClaim]
    public var id: Int { hostPort }
}

public enum PortConflicts {

    public static func conflicts(claims: [PortClaim], snapshot: MonitorSnapshot) -> [PortConflict] {
        let byPort = Dictionary(grouping: snapshot.ports, by: \.port)
        let running = (snapshot.containers ?? []).filter(\.isRunning)
        return claims.compactMap { claim in
            let holders = (byPort[claim.hostPort] ?? []).filter { !isSelf($0, claim) }
            guard !holders.isEmpty else { return nil }
            let runningOn = running
                .filter { $0.composeProject == claim.project && $0.composeService == claim.service }
                .flatMap { $0.ports.map(\.hostPort) }
            return PortConflict(claim: claim, holders: holders, runningOn: runningOn.sorted())
        }
    }

    public static func collisions(claims: [PortClaim]) -> [PortCollision] {
        Dictionary(grouping: claims, by: \.hostPort)
            .compactMap { port, claims in
                Set(claims.map(\.project)).count > 1 ? PortCollision(hostPort: port, claims: claims) : nil
            }
            .sorted { $0.hostPort < $1.hostPort }
    }

    /// The service's own container holding its own port is not a conflict.
    static func isSelf(_ entry: PortEntry, _ claim: PortClaim) -> Bool {
        guard case .container(let c) = entry.owner else { return false }
        return c.composeProject == claim.project && c.composeService == claim.service
    }
}
