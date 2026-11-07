import Foundation
import Yams

/// What a scan of repositories found (DECISIONS 12): services their compose files define and
/// links their variables imply, set against what the catalogue already holds. Hosts and
/// variable names come from files made to be committed; no stored value is ever in here.
public struct ScanResult: Codable, Sendable {
    public struct Found: Codable, Hashable, Sendable {
        public let from: String
        public let link: Link
    }

    /// A reference that names no service: the user binds it (DECISIONS 8).
    public struct Unknown: Codable, Hashable, Sendable {
        public let callers: [String]
        public let file: String
        public var variable: String?
        public var host: String?
        public var port: Int?
        /// A topic variable of a caller with no link to a broker.
        public var topic: String?
        /// The repository a build context points into, when it has no single service.
        public var build: String?
    }

    public struct Repo: Codable, Sendable {
        public let repo: RepoID
        public let project: String
        /// Where it was read; nil — not cloned on this machine, nothing scanned.
        public var clone: String?
        /// Compose services the catalogue does not have: candidates.
        public var services: [Service] = []
        public var new: [Found] = []
        /// Found again and in the catalogue already.
        public var present: [Found] = []
        /// `derived:` links of the catalogue that the files no longer give. Never deleted here.
        public var gone: [Found] = []
        public var unknown: [Unknown] = []
        public var problems: [String] = []
    }

    public var repos: [Repo] = []
    /// External networks → the repositories whose compose files join them. Reported, not written.
    public var networks: [String: [String]] = [:]
}

/// Derives services and links from the files of local clones: compose files read as plain
/// YAML (no interpolation, no docker) and example env files. A real `.env` is never opened.
public enum Scanner {

    /// Compose names that say nothing outside their repository: the id gets the repo's name.
    static let genericNames: Set<String> = [
        "db", "database", "postgres", "postgresql", "pg", "mysql", "mongo", "redis", "cache", "app", "api", "backend",
        "frontend", "web", "ui", "server", "client", "worker", "proxy", "traefik", "nginx", "migrate", "migrations",
        "mq", "rabbitmq", "minio", "s3", "clickhouse", "kafka", "zookeeper", "grafana", "prometheus", "loki", "tools",
    ]
    static let databases: Set<String> = ["postgres", "clickhouse", "redis", "mysql", "mongodb"]
    static let brokers: Set<String> = ["kafka", "rabbitmq"]
    /// One machine under several names; a port is what tells its services apart.
    static let loopback: Set<String> = ["localhost", "127.0.0.1", "::1", "host.docker.internal"]
    static let readWords: Set<String> = ["IN", "INPUT", "CONSUME", "CONSUMER", "SOURCE", "SUB", "SUBSCRIBE"]
    static let writeWords: Set<String> = ["OUT", "OUTPUT", "PRODUCE", "PRODUCER", "SINK", "PUB", "PUBLISH"]

    // MARK: Files

    /// An env file made to be committed: `.default.env`, `.env.example`, `env.example`,
    /// `x.env.example`, `.env.sample` and their like. An allowlist — `.env`, `.env.local`,
    /// `.deploy.env`, `kafka.env` hold secrets and are not opened.
    static func isExampleEnv(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "env.example" || [".default.env", ".env.example", ".env.sample", ".env.default"].contains { lower.hasSuffix($0) }
    }

    static func isComposeFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard lower.hasSuffix(".yml") || lower.hasSuffix(".yaml") else { return false }
        return lower.hasPrefix("docker-compose") || lower.hasPrefix("compose")
    }

    /// The real file an example stands for: `.default.env` and `.env.example` → `.env`.
    static func realCounterpart(_ path: String) -> String {
        if path.lowercased().hasSuffix(".default.env") { return String(path.dropLast(12)) + ".env" }
        let real = (path as NSString).deletingPathExtension
        return real.hasSuffix(".env") ? real : String(real.dropLast(3)) + ".env"      // env.example
    }

    /// Compose files and example env files of a clone, repo-relative, at most three levels down.
    static func files(in clone: URL) -> (compose: [String], env: [String]) {
        var compose: [String] = [], env: [String] = []
        let fm = FileManager.default
        func walk(_ relative: String, depth: Int) {
            guard depth <= 3, let names = try? fm.contentsOfDirectory(atPath: clone.appendingPathComponent(relative).path) else { return }
            for name in names.sorted() {
                let path = relative.isEmpty ? name : relative + "/" + name
                let full = clone.appendingPathComponent(path).path
                var isDir: ObjCBool = false
                // Nothing is read through a link: it may lead to a real `.env`.
                guard (try? fm.destinationOfSymbolicLink(atPath: full)) == nil, fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    if !name.hasPrefix(".") && !Doctor.skippedDirs.contains(name) { walk(path, depth: depth + 1) }
                } else if isComposeFile(name) {
                    compose.append(path)
                } else if isExampleEnv(name) {
                    env.append(path)
                }
            }
        }
        walk("", depth: 0)
        return (compose, env)
    }

    // MARK: Compose

    /// A compose service, united by name across the files of a repository.
    struct ComposeService {
        var image: String?
        var builds = false
        /// Literal values of `environment:`, with the file each is in.
        var variables: [(name: String, value: String, file: String)] = []
        /// Repo-relative paths its `env_file:` names.
        var envFiles: Set<String> = []
        /// Build contexts as absolute paths.
        var contexts: [(path: String, file: String)] = []
    }

    /// A value as written, without interpolation: `${VAR:-default}` gives its default, a value
    /// that needs the environment (`${VAR}`, `$VAR`) gives nil.
    static func literal(_ value: String) -> String? {
        let out = value.replacingOccurrences(of: #"\$\{[A-Za-z_][A-Za-z0-9_]*:?-([^}]*)\}"#, with: "$1", options: .regularExpression)
        return out.contains("$") ? nil : out
    }

    static func inside(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }

    static func read(_ file: String, in clone: URL, into services: inout [String: ComposeService], networks: inout Set<String>) throws {
        let text = try String(contentsOf: clone.appendingPathComponent(file), encoding: .utf8)
        guard let root = try Yams.load(yaml: text) as? [String: Any] else { return }
        // Paths in a compose file are relative to the file.
        let base = clone.appendingPathComponent(file).deletingLastPathComponent()
        func absolute(_ path: String) -> String { URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL.path }
        for (name, raw) in root["services"] as? [String: Any] ?? [:] {
            guard let body = raw as? [String: Any] else { continue }
            var service = services[name] ?? ComposeService()
            service.image = service.image ?? body["image"] as? String
            if let build = body["build"] {
                service.builds = true
                if let context = literal(build as? String ?? (build as? [String: Any])?["context"] as? String ?? ".") {
                    service.contexts.append((absolute(context), file))
                }
            }
            // A map, or a list of `NAME=value`.
            var pairs: [(key: String, value: String)] = []
            if let map = body["environment"] as? [String: Any] {
                pairs = map.compactMap { $0.value is NSNull ? nil : ($0.key, "\($0.value)") }
            } else if let list = body["environment"] as? [Any] {
                pairs = EnvFiles.parseDotenv(list.map { "\($0)" }.joined(separator: "\n"))
            }
            for (key, value) in pairs.sorted(by: { $0.key < $1.key }) {
                if let value = literal(value), !value.isEmpty { service.variables.append((key, value, file)) }
            }
            // A path, or a list of paths or of `{path:, required:}`.
            for entry in body["env_file"] as? [Any] ?? body["env_file"].map({ [$0] }) ?? [] {
                guard let path = entry as? String ?? (entry as? [String: Any])?["path"] as? String else { continue }
                service.envFiles.insert(String(absolute(path).dropFirst(clone.path.count + 1)))
            }
            services[name] = service
        }
        for (key, raw) in root["networks"] as? [String: Any] ?? [:] {
            guard let body = raw as? [String: Any], body["external"] as? Bool == true || body["external"] is [String: Any] else { continue }
            networks.insert(body["name"] as? String ?? key)
        }
    }

    /// `postgres:16-alpine` → postgres, `clickhouse/clickhouse-server` → clickhouse,
    /// `minio/minio` → s3; `provectuslabs/kafka-ui` is not Kafka, so the name is matched whole.
    static func kind(ofImage image: String?) -> String {
        let name = (image ?? "").lowercased().split(separator: "/").last?.split(separator: ":").first.map(String.init) ?? ""
        let kinds = ["postgres": "postgres", "postgis": "postgres", "redis": "redis", "clickhouse": "clickhouse",
                     "kafka": "kafka", "rabbitmq": "rabbitmq", "minio": "s3"]
        return kinds.first { name == $0.key || name == $0.key + "-server" || name.hasSuffix("-" + $0.key) }?.value ?? "http"
    }

    // MARK: Addresses

    struct Target: Hashable {
        var scheme: String?
        var host: String
        var port: Int?
        var path: String?
    }

    /// Addresses in a value: URLs and DSNs (`scheme://user:pw@host:port/path`, `jdbc:` allowed
    /// in front) or bare `host:port`, one or several through commas. Credentials and the query
    /// are dropped here and go nowhere.
    static func addresses(_ value: String) -> [Target] {
        value.split(separator: ",").compactMap { piece -> Target? in
            var text = piece.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("jdbc:") { text.removeFirst(5) }
            if let m = text.wholeMatch(of: #/([A-Za-z][A-Za-z0-9+._-]*)://(?:[^/?#]*@)?([^:/?#@]+)(?::(\d+))?(/[^?#]*)?(?:[?#].*)?/#), m.2 != "0.0.0.0" {
                let path = m.4.map(String.init)
                return Target(scheme: m.1.lowercased(), host: m.2.lowercased(), port: m.3.flatMap { Int($0) }, path: path == "/" ? nil : path)
            }
            // `12:30` is a time and `0.0.0.0:8000` is where a server listens, not whom it calls.
            guard let m = text.wholeMatch(of: #/([A-Za-z0-9._-]+):(\d+)/#), m.1 != "0.0.0.0",
                  m.1.contains(where: \.isLetter) || m.1.split(separator: ".").count == 4 else { return nil }
            return Target(host: m.1.lowercased(), port: Int(m.2))
        }
    }

    /// `X_HOST=name` beside an `X_PORT=n` of the same source is `name:n`; alone it is a host
    /// without a port. A loopback host without a port is nobody's address.
    static func splitHost(_ name: String, _ value: String, port: (String) -> String?) -> Target? {
        let upper = name.uppercased(), host = value.lowercased()
        guard upper.hasSuffix("_HOST"), host.wholeMatch(of: #/[a-z0-9._-]+/#) != nil, host != "0.0.0.0",
              host.contains(where: \.isLetter) || host.split(separator: ".").count == 4 else { return nil }
        let port = port(upper.dropLast(4) + "PORT").flatMap { Int($0) }
        return port == nil && loopback.contains(host) ? nil : Target(host: host, port: port)
    }

    /// The key that is an endpoint's host or whole URL: `${H}:${P}` → H, `${URL}/api` → URL;
    /// nil when the host is put together from several keys or written out.
    static func hostKey(_ endpoint: Service.Endpoint) -> String? {
        guard var template = endpoint.address ?? endpoint.url else { return nil }
        if let scheme = template.range(of: "://") { template = String(template[scheme.upperBound...]) }
        var authority = template.prefix { $0 != "/" }
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        let host = authority.prefix { $0 != ":" }
        let keys = Template.keys(in: String(host))
        return keys.count == 1 && host == "${\(keys[0])}" ? keys[0] : nil
    }

    /// What makes two links of one caller one: found again, a link is not repeated. Only a topic
    /// is told apart by `what`; a curated link's descriptive `what` and `endpoint` do not count.
    static func key(_ link: Link) -> [String?] { [link.to, link.via, link.via == "topic" ? link.what : nil] }

    // MARK: Scan

    /// One clone as its files describe it.
    struct Clone {
        let root: URL
        var report: ScanResult.Repo
        var compose: [String: ComposeService] = [:]
        var envFiles: [String] = []
        /// Compose service → the catalogue's service, or the candidate standing for it.
        var ids: [String: String] = [:]
    }

    /// The repositories asked for: every assigned one, or those of the given projects (with
    /// the projects inside them) and the given addresses.
    static func repos(_ targets: [String], registry: Registry, assigned: [RepoID: String]) throws -> [RepoID] {
        guard !targets.isEmpty else { return assigned.keys.sorted() }
        let projects = try registry.projects()
        var out = Set<RepoID>()
        for target in targets {
            if projects.contains(where: { $0.id == target }) {
                out.formUnion(projects.filter { registry.path(ofProject: $0.id).contains(target) }.flatMap { $0.repos.map(\.repo) })
            } else if let repo = RepoID(target), assigned[repo] != nil {
                out.insert(repo)
            } else {
                throw Registry.Failure("\(target) is neither a project nor a repository of one")
            }
        }
        return out.sorted()
    }

    /// Reads the clones and compares with the catalogue; writes nothing.
    ///
    /// Whose variable it is: one in a service's `environment:` is that service's; one in an
    /// example env file belongs to the services whose `env_file:` names the file or the real
    /// file it stands for, and when no service names it, to every service of the repository
    /// that has `build:`.
    public static func scan(_ asked: [String] = [], registry: Registry = Registry(), store: SecretStore = SecretStore()) throws -> ScanResult {
        let assigned = try registry.assigned()
        let catalog = try registry.services()
        let existing = Dictionary(catalog.map { ($0.id, registry.links(of: $0.id)) }, uniquingKeysWith: { first, _ in first })
        let local = Repos.clones(roots: registry.searchRoots).mapValues { URL(fileURLWithPath: $0).standardizedFileURL }
        var result = ScanResult()
        var clones: [Clone] = []
        // The catalogue plus this run's candidates: a link may lead to either.
        var known = catalog

        for repo in try repos(asked, registry: registry, assigned: assigned) {
            let report = ScanResult.Repo(repo: repo, project: assigned[repo]!, clone: local[repo]?.path)
            guard let root = local[repo] else {
                if !asked.isEmpty { result.repos.append(report) }
                continue
            }
            var clone = Clone(root: root, report: report)
            let listed = files(in: root)
            clone.envFiles = listed.env
            var networks = Set<String>()
            for file in listed.compose {
                do { try read(file, in: root, into: &clone.compose, networks: &networks) }
                catch { clone.report.problems.append("\(file): not read as YAML") }
            }
            for network in networks { result.networks[network, default: []].append(repo.description) }
            // Names that can be ids take them first: `frontend` must not get `<repo>-frontend`
            // ahead of a service called exactly that.
            func order(_ name: String) -> String { (genericNames.contains(name.lowercased()) ? "1" : "0") + name }
            for (name, service) in clone.compose.sorted(by: { order($0.key) < order($1.key) }) {
                // The repository's own service, or — for an image, not a build — shared
                // infrastructure known under this name (`hyper-kafka` is `kafka`).
                if let same = catalog.first(where: { $0.repo == repo && ($0.id == name || $0.aliases.contains(name)) })
                    ?? (service.builds ? nil : catalog.first { $0.aliases.contains(name) }) {
                    clone.ids[name] = same.id
                    continue
                }
                func free(_ id: String) -> Bool { !known.contains { $0.id == id } }
                let id = !genericNames.contains(name.lowercased()) && free(name) ? name : "\(repo.description.split(separator: "/").last!)-\(name)"
                guard free(id), Registry.isValidID(id) else {
                    clone.report.problems.append("\(name): its id \(id) is taken — if it is that service, add \(name) to its aliases")
                    continue
                }
                let candidate = Service(id: id, name: name, kind: kind(ofImage: service.image), repo: repo, aliases: id == name ? [] : [name])
                known.append(candidate)
                clone.report.services.append(candidate)
                clone.ids[name] = id
            }
            clone.report.services.sort { $0.id < $1.id }
            clones.append(clone)
        }

        // Where every endpoint of the catalogue is, per environment. Compared here, never shown.
        var rendered: [(service: Service, endpoint: Service.Endpoint, env: String, at: Target)] = []
        for service in catalog where !service.endpoints.isEmpty {
            for env in service.envs {
                let values = try store.values(service: service.id, env: env)
                for endpoint in service.endpoints {
                    guard let template = endpoint.address ?? endpoint.url, let text = try? Template.render(template, values: values) else { continue }
                    rendered += addresses(text).map { (service, endpoint, env, $0) }
                }
            }
        }
        func normal(_ host: String) -> String { loopback.contains(host) ? "localhost" : host }

        /// A compose service of the repository, then another name of a known service, then an
        /// endpoint at this address (DECISIONS 8). Two services at one address are nobody's.
        func resolve(_ at: Target, _ clone: Clone) -> (to: Service, endpoint: String?, env: String?, key: String?)? {
            let named = clone.ids[at.host].flatMap { id in known.first { $0.id == id } }
                ?? (loopback.contains(at.host) ? nil : known.first { service in
                    service.id == at.host || service.aliases.contains(at.host) || at.port.map { service.aliases.contains("\(at.host):\($0)") } == true
                })
            // By name the endpoint is not known, but with only one its key is.
            if let named { return (named, nil, nil, named.endpoints.count == 1 ? hostKey(named.endpoints[0]) : nil) }
            let host = rendered.filter { normal($0.at.host) == normal(at.host) }
            let exact = host.filter { $0.at.port == at.port }
            let hits = exact.isEmpty && !loopback.contains(at.host) ? host : exact
            guard let first = hits.first, hits.allSatisfy({ $0.service.id == first.service.id }) else { return nil }
            guard hits.allSatisfy({ $0.endpoint.id == first.endpoint.id }) else { return (first.service, nil, nil, nil) }
            return (first.service, first.endpoint.id, hits.allSatisfy { $0.env == first.env } ? first.env : nil, hostKey(first.endpoint))
        }

        for var clone in clones {
            var found: [ScanResult.Found] = []
            func add(_ from: String, _ link: Link) {
                guard link.to != from, !found.contains(where: { $0.from == from && key($0.link) == key(link) }) else { return }
                found.append(.init(from: from, link: link))
            }
            func unknown(_ entry: ScanResult.Unknown) {
                if !clone.report.unknown.contains(entry) { clone.report.unknown.append(entry) }
            }
            let services = clone.compose.sorted { $0.key < $1.key }.compactMap { name, service in clone.ids[name].map { (id: $0, service: service) } }

            var variables: [(callers: [String], name: String, value: String, file: String, envFile: Bool)] = []
            for (id, service) in services { variables += service.variables.map { ([id], $0.name, $0.value, $0.file, false) } }
            for file in clone.envFiles {
                var callers = clone.compose.filter { $0.value.envFiles.contains(file) || $0.value.envFiles.contains(realCounterpart(file)) }
                if callers.isEmpty { callers = clone.compose.filter(\.value.builds) }
                let ids = Set(callers.keys.compactMap { clone.ids[$0] }).sorted()
                guard !ids.isEmpty else {
                    clone.report.problems.append("\(file): no compose service to take its variables")
                    continue
                }
                guard let text = try? String(contentsOf: clone.root.appendingPathComponent(file), encoding: .utf8) else { continue }
                for (name, value) in EnvFiles.parseDotenv(text) {
                    if let value = literal(value), !value.isEmpty { variables.append((ids, name, value, file, true)) }
                }
            }

            for v in variables where !v.name.uppercased().contains("TOPIC") {
                let split = splitHost(v.name, v.value) { port in
                    variables.first { $0.name.uppercased() == port && $0.file == v.file && $0.callers == v.callers }?.value
                }
                for at in addresses(v.value) + (split.map { [$0] } ?? []) {
                    guard let hit = resolve(at, clone) else {
                        unknown(.init(callers: v.callers, file: v.file, variable: v.name, host: at.host, port: at.port))
                        continue
                    }
                    let scheme = at.scheme ?? ""
                    let via = databases.contains(hit.to.kind) || ["postgres", "clickhouse", "redis", "amqp"].contains(where: scheme.hasPrefix) ? "db"
                        : brokers.contains(hit.to.kind) && !scheme.hasPrefix("http") ? "network" : "http"
                    for from in v.callers {
                        add(from, Link(to: hit.to.id, endpoint: hit.endpoint, env: hit.env, via: via, what: via == "http" ? at.path : nil,
                                       names: hit.key.map { [v.name: $0] }, file: hit.key != nil && v.envFile ? v.file : nil,
                                       origin: "derived:\(v.file)"))
                    }
                }
            }

            // A topic goes to the broker its caller is linked to: by the same file first, then
            // by any file of this scan, then by the catalogue. A number or a flag is a setting
            // of the broker itself (`KAFKA_AUTO_CREATE_TOPICS_ENABLE=true`), not a topic.
            for v in variables where v.name.uppercased().contains("TOPIC") && Double(v.value) == nil && Bool(v.value) == nil {
                let words = Set(v.name.uppercased().split(separator: "_").map(String.init))
                let access = !words.isDisjoint(with: readWords) ? "read" : !words.isDisjoint(with: writeWords) ? "write" : nil
                var without: [String] = []
                for from in v.callers {
                    let mine = found.filter { $0.from == from }.map(\.link)
                    let links = mine.filter { $0.origin == "derived:\(v.file)" } + mine + (existing[from] ?? [])
                    guard let broker = links.first(where: { link in known.contains { $0.id == link.to && brokers.contains($0.kind) } }) else {
                        without.append(from)
                        continue
                    }
                    add(from, Link(to: broker.to, via: "topic", what: v.value, access: access, origin: "derived:\(v.file)"))
                }
                if !without.isEmpty { unknown(.init(callers: without, file: v.file, variable: v.name, topic: v.value)) }
            }

            // A build context in another catalogued repository's clone.
            for (id, service) in services {
                for context in service.contexts where !inside(context.path, clone.root.path) {
                    guard let other = local.first(where: { $0.key != clone.report.repo && assigned[$0.key] != nil && inside(context.path, $0.value.path) }) else { continue }
                    let theirs = known.filter { $0.repo == other.key }
                    guard theirs.count == 1 else {
                        unknown(.init(callers: [id], file: context.file, build: other.key.description))
                        continue
                    }
                    let path = String(context.path.dropFirst(other.value.path.count + 1))
                    add(id, Link(to: theirs[0].id, via: "build", what: path.isEmpty ? nil : path, origin: "derived:\(context.file)"))
                }
            }

            for entry in found {
                if (existing[entry.from] ?? []).contains(where: { key($0) == key(entry.link) }) { clone.report.present.append(entry) }
                else { clone.report.new.append(entry) }
            }
            for service in catalog where service.repo == clone.report.repo {
                for link in existing[service.id] ?? [] where (link.origin ?? "").hasPrefix("derived:")
                    && !found.contains(where: { $0.from == service.id && key($0.link) == key(link) }) {
                    clone.report.gone.append(.init(from: service.id, link: link))
                }
            }
            result.repos.append(clone.report)
        }
        result.repos.sort { $0.repo < $1.repo }
        result.networks = result.networks.mapValues { $0.sorted() }
        return result
    }

    /// Writes the candidates' cards and the new links and commits nothing: they wait in
    /// `pending` for the user (DECISIONS 19). Gone links stay where they are.
    @discardableResult
    public static func write(_ result: ScanResult, registry: Registry = Registry()) throws -> [URL] {
        // Every card first: a link may lead to a candidate of another repository.
        var files = try result.repos.flatMap { repo in try repo.services.map { try registry.draft($0, in: repo.project) } }
        for repo in result.repos { for found in repo.new { files.append(try registry.addLink(found.link, from: found.from)) } }
        return Array(Set(files))
    }
}
