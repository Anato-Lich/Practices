import Foundation

/// A TCP socket in LISTEN state, as `lsof` sees it.
public struct ListeningSocket: Hashable, Sendable, Codable {
    public let port: Int
    public let address: String      // "*", "127.0.0.1", "[::1]"
    public let pid: Int32
    public let command: String

    public var isLoopbackOnly: Bool {
        address == "127.0.0.1" || address == "[::1]" || address == "localhost"
    }
}

public enum ListeningPorts {

    /// Every listening TCP socket of the current user's processes (lsof without root sees
    /// only those, which is the set we can act on anyway).
    public static func scan() async throws -> [ListeningSocket] {
        let output = try await Shell.run(
            "lsof", ["-iTCP", "-sTCP:LISTEN", "-P", "-n", "-F", "pcn"], allowedStatuses: [0, 1])
        return parse(lsofFields: output)
    }

    /// Parses `lsof -F pcn`: a `p<pid>` line opens a process, `c<command>` names it, then one
    /// `f<fd>` + `n<address:port>` pair per socket. IPv4 and IPv6 listeners on the same port
    /// collapse into one entry.
    static func parse(lsofFields output: String) -> [ListeningSocket] {
        var result: [ListeningSocket] = []
        var seen = Set<String>()
        var pid: Int32 = 0
        var command = ""
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": command = value
            case "n":
                guard let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]) else { continue }
                let address = String(value[..<colon])
                let key = "\(pid):\(port)"
                if seen.insert(key).inserted {
                    result.append(ListeningSocket(port: port, address: address, pid: pid, command: command))
                } else if address == "*" || address == "[::]",
                          let i = result.firstIndex(where: { $0.pid == pid && $0.port == port }) {
                    // A wildcard listener on either family is the one that matters.
                    result[i] = ListeningSocket(port: port, address: "*", pid: pid, command: command)
                }
            default: continue
            }
        }
        return result.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    /// Working directories of the given processes, for attributing a bare `node` or
    /// `python` listener to the project it was started from.
    public static func workingDirectories(of pids: [Int32]) async -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        guard let output = try? await Shell.run(
            "lsof", ["-a", "-p", list, "-d", "cwd", "-F", "pn"], allowedStatuses: [0, 1])
        else { return [:] }
        var result: [Int32: String] = [:]
        var pid: Int32 = 0
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) ?? 0 }
            else if line.hasPrefix("n") { result[pid] = String(line.dropFirst()) }
        }
        return result
    }
}
