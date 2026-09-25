import Foundation
import Network

/// Result of probing one endpoint. Messages name the target, never its host: hosts come from
/// the secret store.
public struct CheckResult: Hashable, Sendable, Codable {
    public let source: String
    public let env: String
    public let target: String           // target id, or "requires" for a precondition
    public let ok: Bool
    public let millis: Int?
    public let message: String?

    public init(source: String, env: String, target: String, ok: Bool, millis: Int?, message: String?) {
        self.source = source; self.env = env; self.target = target
        self.ok = ok; self.millis = millis; self.message = message
    }
}

public enum Checks {

    /// Preconditions of a source in an environment; an empty list means all hold.
    public static func unmet(_ source: Source, env: String, values: [String: String]) async -> [String] {
        var failures: [String] = []
        for requirement in source.requires {
            let result = await probe(hostPort: requirement.reachable, values: values)
            if !result.ok {
                failures.append(requirement.hint ?? "\(source.name): not reachable (\(result.message ?? "no answer"))")
            }
        }
        return failures
    }

    /// Every target of a source, concurrently.
    public static func check(_ source: Source, env: String, values: [String: String]) async -> [CheckResult] {
        await withTaskGroup(of: CheckResult.self) { group in
            for target in source.targets {
                group.addTask {
                    let (ok, ms, message): (Bool, Int?, String?)
                    if let url = target.url {
                        (ok, ms, message) = await probe(url: url, values: values)
                    } else if let address = target.address {
                        let r = await probe(hostPort: address, values: values)
                        (ok, ms, message) = (r.ok, r.millis, r.message)
                    } else {
                        (ok, ms, message) = (false, nil, "target has neither url nor address")
                    }
                    return CheckResult(source: source.id, env: env, target: target.id, ok: ok, millis: ms, message: message)
                }
            }
            var results: [CheckResult] = []
            for await r in group { results.append(r) }
            let order = source.targets.map(\.id)
            return results.sorted { (order.firstIndex(of: $0.target) ?? 0) < (order.firstIndex(of: $1.target) ?? 0) }
        }
    }

    static func probe(hostPort template: String, values: [String: String]) async -> (ok: Bool, millis: Int?, message: String?) {
        let rendered: String
        do { rendered = try Template.render(template, values: values) } catch { return (false, nil, String(describing: error)) }
        // A bootstrap list (`a:9092,b:9092`) is checked by its first entry.
        let first = rendered.split(separator: ",").first.map(String.init) ?? rendered
        guard let colon = first.lastIndex(of: ":"), let port = UInt16(first[first.index(after: colon)...]) else {
            return (false, nil, "not host:port")
        }
        let host = String(first[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        return await tcpConnect(host: host, port: port, timeout: 4)
    }

    static func probe(url template: String, values: [String: String]) async -> (Bool, Int?, String?) {
        let rendered: String
        do { rendered = try Template.render(template, values: values) } catch { return (false, nil, String(describing: error)) }
        guard let url = URL(string: rendered) else { return (false, nil, "not a URL") }
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.httpMethod = "GET"
        let start = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            // Any HTTP answer means the service is there; auth is the practices' business.
            let code = (response as? HTTPURLResponse)?.statusCode
            return (true, ms, code.map { "HTTP \($0)" })
        } catch let error as URLError {
            return (false, nil, describe(error.code))
        } catch {
            return (false, nil, "request failed")
        }
    }

    static func describe(_ code: URLError.Code) -> String {
        switch code {
        case .timedOut: "timed out"
        case .cannotConnectToHost: "connection refused"
        case .cannotFindHost, .dnsLookupFailed: "host not found"
        case .notConnectedToInternet: "offline"
        case .appTransportSecurityRequiresSecureConnection: "blocked by App Transport Security"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate: "TLS failed"
        default: "request failed (\(code.rawValue))"
        }
    }

    static func tcpConnect(host: String, port: UInt16, timeout: TimeInterval) async -> (ok: Bool, millis: Int?, message: String?) {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let start = Date()
        let box = OnceBox()
        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ result: (Bool, Int?, String?)) {
                guard box.claim() else { return }
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish((true, Int(Date().timeIntervalSince(start) * 1000), nil))
                case .failed(let error): finish((false, nil, message(for: error)))
                case .waiting(let error): finish((false, nil, message(for: error)))
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish((false, nil, "timed out")) }
        }
    }

    static func message(for error: NWError) -> String {
        switch error {
        case .posix(let code) where code == .ECONNREFUSED: "connection refused"
        case .posix(let code) where code == .ETIMEDOUT: "timed out"
        case .posix(let code) where code == .ENETUNREACH || code == .EHOSTUNREACH: "network unreachable"
        case .dns: "host not found"
        default: "connection failed"
        }
    }
}

final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

/// The environment a command runs with: values of the referenced sources merged (PLAN §3.1 —
/// the project reads `os.environ` and knows nothing about Practices).
public enum RunEnvironment {

    public struct Conflict: Error, CustomStringConvertible, Sendable {
        public let key: String
        public let sources: [String]
        public var description: String {
            "\(key) has different values in \(sources.joined(separator: " and "))"
        }
    }

    public struct Unknown: Error, CustomStringConvertible, Sendable {
        public let ref: String
        public let reason: String
        public var description: String { "\(ref): \(reason)" }
    }

    public struct Resolved: Sendable {
        public let values: [String: String]
        public let sources: [(source: Source, env: String)]
        /// Keys a source declares but has no value for, per `source@env`.
        public let missing: [String: [String]]
    }

    /// `aliases` (project variable → registry key) add the project's own names for values.
    public static func resolve(_ refs: [SourceRef], aliases: [String: String] = [:], registry: Registry = Registry(),
                               store: SecretStore = SecretStore()) throws -> Resolved {
        var values: [String: String] = [:]
        var owner: [String: String] = [:]
        var sources: [(Source, String)] = []
        var missing: [String: [String]] = [:]
        for ref in refs {
            guard let source = try? registry.source(ref.source) else {
                throw Unknown(ref: ref.description, reason: "no such source in the registry")
            }
            let env = ref.env ?? source.defaultEnv
            guard source.envs.contains(env) else {
                throw Unknown(ref: ref.description, reason: "environments are " + source.envs.joined(separator: ", "))
            }
            let own = try store.values(source: source.id, env: env)
            let absent = source.keys.map(\.name).filter { (own[$0] ?? "").isEmpty }
            if !absent.isEmpty { missing["\(source.id)@\(env)"] = absent }
            for (key, value) in own where source.keys.contains(where: { $0.name == key }) {
                if let existing = values[key], existing != value {
                    throw Conflict(key: key, sources: [owner[key]!, "\(source.id)@\(env)"])
                }
                values[key] = value
                owner[key] = "\(source.id)@\(env)"
            }
            sources.append((source, env))
        }
        for (projectName, key) in aliases {
            if let value = values[key] { values[projectName] = value }
            else { missing["alias \(projectName)", default: []].append(key) }
        }
        return Resolved(values: values, sources: sources, missing: missing)
    }
}
