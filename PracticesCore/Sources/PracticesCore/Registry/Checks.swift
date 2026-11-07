import Foundation
import Network

/// Result of probing one endpoint or one condition. Messages name the endpoint, never its
/// host: hosts come from the secret store.
public struct CheckResult: Hashable, Sendable, Codable {
    public let service: String
    public let env: String
    public let endpoint: String         // endpoint id, or "requires:<condition id>"
    public let ok: Bool
    public let millis: Int?
    public let message: String?

    public init(service: String, env: String, endpoint: String, ok: Bool, millis: Int?, message: String?) {
        self.service = service; self.env = env; self.endpoint = endpoint
        self.ok = ok; self.millis = millis; self.message = message
    }
}

public enum Checks {

    /// The conditions of a service and its endpoints (DECISIONS 11). One with a `reachable`
    /// template is probed, and its hint is the message when the probe fails; one without is
    /// declared knowledge and holds. A template over keys this service has no values for
    /// cannot be checked from here and does not fail the service.
    public static func conditions(_ service: Service, env: String, values: [String: String],
                                  registry: Registry = Registry()) async -> [CheckResult] {
        var results: [CheckResult] = []
        for id in service.conditionIDs {
            func result(_ ok: Bool, _ millis: Int? = nil, _ message: String? = nil) -> CheckResult {
                CheckResult(service: service.id, env: env, endpoint: "requires:\(id)", ok: ok, millis: millis, message: message)
            }
            guard let condition = registry.condition(id) else {
                results.append(result(false, nil, "condition \(id) is not declared in any space"))
                continue
            }
            guard let template = condition.reachable else { results.append(result(true, nil, condition.hint)); continue }
            guard (try? Template.render(template, values: values)) != nil else {
                results.append(result(true, nil, "not checked: no values here for its address"))
                continue
            }
            let r = await probe(hostPort: template, values: values)
            results.append(result(r.ok, r.millis, r.ok ? nil
                : condition.hint ?? "\(condition.name): not reachable (\(r.message ?? "no answer"))"))
        }
        return results
    }

    /// Messages of the conditions that do not hold; an empty list means all hold. Asked before
    /// a run, so a missing tunnel fails with a sentence instead of a timeout.
    public static func unmet(_ service: Service, env: String, values: [String: String],
                             registry: Registry = Registry()) async -> [String] {
        await conditions(service, env: env, values: values, registry: registry).filter { !$0.ok }.compactMap(\.message)
    }

    /// Conditions of these services that are declared and never probed (an authorisation, an
    /// office-only network), each once: what to show beside a failed run, whose bare `401`
    /// says nothing of the hint.
    public static func declared(_ services: [Service], registry: Registry = Registry()) -> [Condition] {
        var seen = Set<String>()
        return services.flatMap(\.conditionIDs).filter { seen.insert($0).inserted }
            .compactMap(registry.condition).filter { $0.reachable == nil }
    }

    /// Every endpoint of a service, concurrently.
    public static func check(_ service: Service, env: String, values: [String: String]) async -> [CheckResult] {
        await withTaskGroup(of: CheckResult.self) { group in
            for endpoint in service.endpoints {
                group.addTask {
                    let (ok, ms, message): (Bool, Int?, String?)
                    if let url = endpoint.url {
                        (ok, ms, message) = await probe(url: url, values: values)
                    } else if let address = endpoint.address {
                        let r = await probe(hostPort: address, values: values)
                        (ok, ms, message) = (r.ok, r.millis, r.message)
                    } else {
                        (ok, ms, message) = (false, nil, "endpoint has neither url nor address")
                    }
                    return CheckResult(service: service.id, env: env, endpoint: endpoint.id, ok: ok, millis: ms, message: message)
                }
            }
            var results: [CheckResult] = []
            for await r in group { results.append(r) }
            let order = service.endpoints.map(\.id)
            return results.sorted { (order.firstIndex(of: $0.endpoint) ?? 0) < (order.firstIndex(of: $1.endpoint) ?? 0) }
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

/// The environment a command runs with: values of the referenced services merged (the project
/// reads `os.environ` and knows nothing about Practices).
public enum RunEnvironment {

    public struct Conflict: Error, CustomStringConvertible, Sendable {
        public let key: String
        public let services: [String]
        public var description: String {
            "\(key) has different values in \(services.joined(separator: " and "))"
        }
    }

    public struct Unknown: Error, CustomStringConvertible, Sendable {
        public let ref: String
        public let reason: String
        public var description: String { "\(ref): \(reason)" }
    }

    public struct Resolved: Sendable {
        public let values: [String: String]
        public let services: [(service: Service, env: String)]
        /// Keys a service declares but has no value for, per `service@env`.
        public let missing: [String: [String]]
    }

    public static func resolve(_ refs: [ServiceRef], registry: Registry = Registry(),
                               store: SecretStore = SecretStore()) throws -> Resolved {
        var values: [String: String] = [:]
        var owner: [String: String] = [:]
        var services: [(Service, String)] = []
        var missing: [String: [String]] = [:]
        for ref in refs {
            guard let service = try? registry.service(ref.service) else {
                throw Unknown(ref: ref.description, reason: "no such service in the registry")
            }
            let env = ref.env ?? service.defaultEnv
            guard service.envs.contains(env) else {
                throw Unknown(ref: ref.description, reason: "environments are " + service.envs.joined(separator: ", "))
            }
            let own = try store.values(service: service.id, env: env)
            let absent = service.keys.map(\.name).filter { (own[$0] ?? "").isEmpty }
            if !absent.isEmpty { missing["\(service.id)@\(env)"] = absent }
            for (key, value) in own where service.keys.contains(where: { $0.name == key }) {
                if let existing = values[key], existing != value {
                    throw Conflict(key: key, services: [owner[key]!, "\(service.id)@\(env)"])
                }
                values[key] = value
                owner[key] = "\(service.id)@\(env)"
            }
            services.append((service, env))
        }
        return Resolved(values: values, services: services, missing: missing)
    }
}
