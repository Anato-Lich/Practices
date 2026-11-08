import Foundation

/// Practices for an agent working in a project: stdio MCP, one JSON-RPC message per line.
/// Everything the window shows is reachable from here (DECISIONS 14). Values of secrets are
/// never returned — the agent sees names of variables and writes code against them
/// (DECISIONS 4). Services tagged `pii` return shapes, not rows.
public final class MCPServer: @unchecked Sendable {

    let registry: Registry
    let secrets = SecretStore()
    lazy var store = PracticeStore(registry: registry)
    /// The directory the agent's project is in (the server's cwd), named in notes it leaves.
    let origin: String

    public init(origin: String = FileManager.default.currentDirectoryPath, registry: Registry = Registry()) {
        self.origin = origin
        self.registry = registry
    }

    static let instructions = """
        Practices is the user's catalogue of their projects: *spaces* (an organisation) hold \
        *projects* (which nest: a project may have a parent), a project holds *repositories* \
        (known by remote address, not by folder) and \
        *services* — a compose service of a repository or an external system (a database, an \
        API, Kafka). A service has one id, unique everywhere, *endpoints* (addresses), \
        credentials by name, notes, a dictionary of result fields, *conditions* (e.g. "needs \
        the corporate network" — read them before the first request), *links* ("this service \
        calls that one, this way, for this reason"; kept at the caller) and *practices*: small, \
        tested Python functions `run(...)` that query the service, plus *chains* that combine them.

        Start here instead of walking GitLab, GitHub and local folders: `list_projects` / \
        `get_project` for what belongs where and where the clones are, `get_service` for how a \
        service is reached and who uses it, `search` for a field or an operation. Before a new \
        project or service, or a change to compose, env files or IDE tasks, read the space's \
        `get_conventions`: the owner's file names, modules, ports and templates.

        Before writing code that reads one of these services, `search` and `get_practice`: reuse \
        the practice instead of writing a new client. Copy its code as given — the first line \
        `# practices: <ref>@v<N>` is how the copy is tracked; keep it. Credentials: the code \
        reads environment variables by name (`env_names` lists them); values are never available \
        to you. The project gets them by running under `practicesctl run <service>… -- <command>`.

        When you fix or improve a practice, or write a new one, send it with `update_practice`; \
        when you learn that one service calls another, record it with `add_link`; a derived link \
        the code shows to be false goes to `reject_link`, not away. These are left \
        as uncommitted changes the user reviews and accepts — say so, and do not treat them as \
        versions yet. Pitfalls go to `add_note`, field meanings to `describe_field`; those are \
        saved at once.
        """

    // MARK: Loop

    public func serve() {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let id = message["id"]
            let method = message["method"] as? String ?? ""
            let params = message["params"] as? [String: Any] ?? [:]
            guard id != nil else { continue }   // notifications need no answer
            let semaphore = DispatchSemaphore(value: 0)
            let box = ResponseBox()
            // Detached: the caller may be the main actor (main.swift), which is blocked below.
            let sendableParams = UncheckedBox(params)
            Task.detached {
                box.value = await self.handle(method: method, params: sendableParams.value)
                semaphore.signal()
            }
            semaphore.wait()
            send(id: id!, outcome: box.value!)
        }
    }

    final class ResponseBox: @unchecked Sendable { var value: Result<Any, RPCError>? }
    struct UncheckedBox<T>: @unchecked Sendable { let value: T; init(_ value: T) { self.value = value } }

    struct RPCError: Error { let code: Int; let message: String }

    func send(id: Any, outcome: Result<Any, RPCError>) {
        var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
        switch outcome {
        case .success(let result): response["result"] = result
        case .failure(let error): response["error"] = ["code": error.code, "message": error.message]
        }
        if let data = try? JSONSerialization.data(withJSONObject: response),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    func handle(method: String, params: [String: Any]) async -> Result<Any, RPCError> {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? "2025-06-18"
            return .success([
                "protocolVersion": requested,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "practices", "version": "0.5.0"],
                "instructions": Self.instructions,
            ] as [String: Any])
        case "ping":
            return .success([String: Any]())
        case "tools/list":
            return .success(["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let value = try await call(name, args)
                return .success(["content": [["type": "text", "text": Self.json(value)]], "isError": false] as [String: Any])
            } catch {
                return .success(["content": [["type": "text", "text": String(describing: error)]], "isError": true] as [String: Any])
            }
        default:
            return .failure(RPCError(code: -32601, message: "method not found: \(method)"))
        }
    }

    // MARK: Tools

    struct ToolError: Error, CustomStringConvertible { let description: String }

    static func string(_ args: [String: Any], _ key: String) throws -> String {
        guard let v = args[key] as? String, !v.isEmpty else { throw ToolError(description: "missing argument: \(key)") }
        return v
    }

    static func params(_ value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }
        return dict.mapValues { v in
            if let s = v as? String { return s }
            if let data = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]) {
                return String(decoding: data, as: UTF8.self)
            }
            return "\(v)"
        }
    }

    func call(_ name: String, _ args: [String: Any]) async throws -> Any {
        switch name {
        case "list_projects": return try listProjects()
        case "get_project": return try getProject(try Self.string(args, "id"))
        case "list_services": return try listServices(project: args["project"] as? String)
        case "get_conventions":
            let space = try Self.string(args, "space")
            _ = try registry.space(space)
            return ["space": space, "conventions": registry.conventions(of: space) as Any,
                    "templates": registry.templates(of: space).map { ["path": $0.path, "text": $0.text] }] as [String: Any]
        case "get_service": return try getService(try Self.string(args, "id"))
        case "list_practices": return try await listPractices(args["service"] as? String)
        case "get_practice": return try await getPractice(try Self.string(args, "ref"), version: args["version"] as? Int)
        case "search":
            let query = try Self.string(args, "query")
            var out = try encodable(Search.run(query, registry: registry, store: store)) as? [String: Any] ?? [:]
            let (hits, files) = await ProjectCode.search(query, registry: registry, limit: 20)
            out["project_code"] = try encodable(hits)
            out["project_code_files"] = files
            return out
        case "run_practice":
            return try await runPractice(try Self.string(args, "ref"), params: Self.params(args["params"]),
                                         envs: Self.params(args["envs"]), rows: args["rows"] as? Int ?? 20)
        case "env_names": return try envNames(args["refs"] as? [String] ?? [])
        case "list_copies": return try encodable(await Copies.scan(store: store).filter { copy in
            (args["ref"] as? String).map { $0 == copy.ref } ?? true })
        case "update_practice":
            return try await updatePractice(try Self.string(args, "ref"), code: try Self.string(args, "code"),
                                            project: args["project"] as? String)
        case "add_link":
            // A JSON object has no order to keep; sorted, a rewrite does not shuffle it.
            let names = Link.Names(Self.params(args["names"]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
            let link = Link(to: try Self.string(args, "to"), endpoint: args["endpoint"] as? String, env: args["env"] as? String,
                            via: args["via"] as? String, what: args["what"] as? String, access: args["access"] as? String,
                            why: args["why"] as? String, practice: args["practice"] as? String,
                            names: names.isEmpty ? nil : names, file: args["file"] as? String,
                            origin: args["origin"] as? String ?? "manual")
            let file = try registry.addLink(link, from: try Self.string(args, "from"))
            return ["written": true, "file": file.path, "pending": true,
                    "note": "Left uncommitted: the user reviews and accepts it (practicesctl pending / accept)."]
        case "reject_link":
            let link = Link(to: try Self.string(args, "to"), via: args["via"] as? String, what: args["what"] as? String)
            let files = try registry.reject(link, from: try Self.string(args, "from"), why: try Self.string(args, "why"),
                                            origin: args["origin"] as? String ?? "manual")
            return ["written": true, "files": files.map(\.path), "pending": true,
                    "note": "Left uncommitted: the user reviews and accepts it (practicesctl pending / accept)."]
        case "scan_links":
            return try encodable(Scanner.scan([try Self.string(args, "target")], registry: registry, store: secrets))
        case "describe_field":
            return try await describeField(service: try Self.string(args, "service"), path: try Self.string(args, "path"),
                                           meaning: try Self.string(args, "meaning"),
                                           values: Self.params(args["values"]), from: args["from"] as? String)
        case "add_note":
            return try await addNote(service: try Self.string(args, "service"), text: try Self.string(args, "text"))
        case "setup_status":
            return try encodable(await Setup.status(registry: registry))
        case "setup_agents":
            if let project = args["project"] as? String, !project.isEmpty {
                return try encodable(Setup.project(project, registry: registry))
            }
            let tools = try (args["tools"] as? [String])?.map { name in
                guard let tool = AgentTool(rawValue: name) else { throw ToolError(description: "tools are claude, codex, cursor") }
                return tool
            }
            guard let scope = (args["scope"] as? String).flatMap(InstructionScope.init) else {
                throw ToolError(description: "scope is global or projects: ask the user which")
            }
            return try encodable(Setup.agents(registry: registry, tools: tools, mcp: args["mcp"] as? Bool ?? true,
                                              instructions: args["instructions"] as? Bool ?? true, scope: scope))
        default:
            throw ToolError(description: "unknown tool \(name)")
        }
    }

    func encodable<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
    }

    func listProjects() throws -> Any {
        let services = try registry.services()
        let projects = try registry.projects()
        return Registry.tree(projects).map { project, _ -> [String: Any] in
            ["id": project.id, "space": project.space, "name": project.name, "description": project.description ?? "",
             "parent": project.parent as Any, "children": projects.filter { $0.parent == project.id }.map(\.id),
             "repos": project.repos.map { ["repo": $0.repo.description, "role": $0.role ?? ""] },
             "folders": project.folders.map(\.name), "hosts": hosts(of: project),
             "services": services.filter { $0.project == project.id }.map(\.id)]
        }
    }

    func getProject(_ id: String) throws -> Any {
        let project = try registry.project(id)
        let clones = Repos.clones(roots: registry.searchRoots)
        return [
            "id": project.id, "space": project.space, "name": project.name, "description": project.description ?? "",
            "path": ([project.space] + registry.path(ofProject: id)).joined(separator: " / "),
            "parent": project.parent as Any,
            "children": try registry.projects(space: project.space).filter { $0.parent == id }.map(\.id),
            "repos": project.repos.map { ["repo": $0.repo.description, "role": $0.role ?? "", "clone_url": $0.repo.sshURL,
                                          "local_clone": clones[$0.repo] as Any] as [String: Any] },
            "folders": project.folders.map { ["name": $0.name, "path": registry.local.folders[$0.name] as Any] as [String: Any] },
            "hosts": hosts(of: project),
            "services": try registry.services(project: id).map {
                ["id": $0.id, "name": $0.name, "kind": $0.kind, "description": $0.description ?? "", "repo": $0.repo?.description as Any] as [String: Any]
            },
            "chains": store.chains(project: id).map(\.ref),
        ] as [String: Any]
    }

    /// The servers a project is deployed on, as the conditions name them; a template, never a value.
    func hosts(of project: Project) -> [[String: Any]] {
        project.hosts.map { id in
            let condition = registry.condition(id)
            return ["id": id, "name": condition?.name ?? "(not declared)", "hint": condition?.hint ?? ""]
        }
    }

    func card(_ service: Service) -> [String: Any] {
        let status = (try? secrets.status(service: service)) ?? [:]
        return [
            "id": service.id, "space": service.space, "project": service.project,
            "path": ([service.space] + registry.path(ofProject: service.project) + [service.id]).joined(separator: " / "),
            "name": service.name, "kind": service.kind, "description": service.description ?? "",
            "tags": service.tags, "repo": service.repo?.description as Any, "aliases": service.aliases,
            "envs": service.envs, "guards": service.guards,
            "keys": service.keys.map { key in
                ["name": key.name, "secret": key.secret,
                 "set": Dictionary(uniqueKeysWithValues: service.envs.map { ($0, status[$0]?.contains(key.name) == true) })] as [String: Any]
            },
            "practices": store.list(service: service.id).map(\.ref),
            "hosts": (try? registry.project(service.project)).map(hosts(of:)) ?? [],
        ]
    }

    func listServices(project: String?) throws -> Any {
        try registry.services(project: project).map(card)
    }

    /// Conditions as the agent should read them before the first request: what, and what to do.
    func conditions(of service: Service) -> [[String: Any]] {
        service.conditionIDs.map { id in
            let condition = registry.condition(id)
            let endpoints = service.endpoints.filter { $0.requires.contains(id) }.map(\.id)
            return ["id": id, "name": condition?.name ?? "(not declared)", "hint": condition?.hint ?? "",
                    "applies_to": service.requires.contains(id) ? "the whole service" : "endpoints: " + endpoints.joined(separator: ", ")]
        }
    }

    func getService(_ id: String) throws -> Any {
        let service = try registry.service(id)
        var card = card(service)
        // Templates over key names: where each endpoint is, without any value.
        card["endpoints"] = service.endpoints.map {
            ["id": $0.id, "label": $0.label ?? "", "address": ($0.address ?? $0.url) ?? "", "requires": $0.requires] as [String: Any]
        }
        card["conditions"] = conditions(of: service)
        let role = ServiceMap.role(of: service, in: try registry.catalogue())
        card["role"] = role.rawValue
        card["role_inferred"] = service.role != role.rawValue
        card["links_out"] = try encodable(registry.links(of: id))
        card["links_in"] = try registry.links(to: id).map { from, link -> Any in
            var entry = try encodable(link) as? [String: Any] ?? [:]
            entry["from"] = from
            entry["to"] = nil
            return entry
        }
        card["notes"] = registry.notes(of: id) ?? ""
        card["docs"] = try encodable(registry.docs(of: id))
        card["fields"] = try encodable(registry.fields(of: id))
        return card
    }

    func listPractices(_ service: String?) async throws -> Any {
        let list = service.map { store.list(service: $0) } ?? store.all()
        let runs = try? RunsStore()
        var out: [[String: Any]] = []
        for p in list {
            let last = runs?.runs(of: p.ref, limit: 1).first
            out.append([
                "ref": p.ref, "chain": p.isChain,
                "summary": Self.docstring(of: (try? store.code(of: p)) ?? "") ?? "",
                "versions": (try? await store.versions(of: p).count) ?? 0,
                "last_run": last.map { ["ok": $0.ok, "ms": $0.millis, "rows": $0.rows as Any] } as Any,
            ])
        }
        return out
    }

    func getPractice(_ ref: String, version: Int?) async throws -> Any {
        let practice = Practice(ref: ref)
        let versions = try await store.versions(of: practice)
        guard !versions.isEmpty else { throw ToolError(description: "no practice \(ref) (or it has no accepted version yet)") }
        let v = min(max(version ?? versions.count, 1), versions.count)
        let code = try await store.code(of: practice, at: versions[v - 1])
        let services = store.services(for: practice).compactMap { try? registry.service($0) }
        var schema: Any = []
        if let last = (try? RunsStore())?.runs(of: ref, limit: 20).first(where: { $0.ok && $0.schema != nil }),
           let data = last.schema?.data(using: .utf8) {
            schema = (try? JSONSerialization.jsonObject(with: data)) ?? []
        }
        return [
            "ref": ref, "version": v, "latest": versions.count,
            "code": Copies.stamped(code, ref: ref, version: v),
            "copy_note": "Keep the first line: it marks the copy so updates can find it.",
            "pending_change": await store.isDraft(practice),
            "uses": store.dependencies(of: practice).map(\.ref),
            "services": services.map(\.id), "env_names": services.flatMap { $0.keys.map(\.name) },
            "conditions": services.flatMap(conditions(of:)),
            "result_fields": schema,
            "history": versions.reversed().prefix(10).map { ["version": $0.number, "message": $0.message,
                                                             "date": ISO8601DateFormatter().string(from: $0.date)] },
        ] as [String: Any]
    }

    func runPractice(_ ref: String, params: [String: String], envs: [String: String], rows: Int) async throws -> Any {
        let practice = Practice(ref: ref)
        let result = try await PracticeRunner(store: store, secrets: secrets).run(practice, params: params, envs: envs)
        let pii = store.services(for: practice).contains { ((try? registry.service($0))?.tags ?? []).contains("pii") }
        var out: [String: Any] = [
            "ok": result.ok, "ms": result.ms, "total": result.total as Any, "bytes": result.bytes as Any,
            "shape": result.shape as Any, "version": result.version as Any,
            "environments": result.envs, "schema": try encodable(result.schema ?? []),
            "steps": result.steps.map { ["ref": $0.ref, "ok": $0.ok, "ms": $0.ms, "rows": $0.total as Any, "error": $0.error as Any] },
        ]
        if let error = result.error {
            out["error"] = error
            out["traceback"] = String((result.traceback ?? "").suffix(3000))
        }
        if let conditions = result.conditions {
            out["conditions"] = conditions.map { ["id": $0.id, "name": $0.name, "hint": $0.hint ?? ""] }
        }
        if pii {
            out["note"] = "a service is tagged pii: rows are not returned, only their shape"
        } else {
            let limit = min(max(rows, 0), 200)
            out["columns"] = result.columns as Any
            out["rows"] = try encodable(Array((result.rows ?? []).prefix(limit)))
            if let tree = result.tree { out["tree"] = String(Self.json(try encodable(tree)).prefix(20_000)) }
            if let text = result.text { out["text"] = String(text.prefix(20_000)) }
            if !result.stdout.isEmpty { out["stdout"] = String(result.stdout.suffix(5000)) }
        }
        return out
    }

    func envNames(_ refs: [String]) throws -> Any {
        let list = refs.map(ServiceRef.init(parsing:))
        guard !list.isEmpty else { throw ToolError(description: "give refs like [\"xkdb\", \"kafka@dev\"]") }
        let resolved = try RunEnvironment.resolve(list, registry: registry, store: secrets)
        return [
            "variables": resolved.values.keys.sorted(),
            "missing": resolved.missing,
            "run_with": "practicesctl run \(list.map(\.description).joined(separator: " ")) -- <command>",
            "write_file": "practicesctl connect \(list.map(\.description).joined(separator: " ")) --to .env [--as PROJECT_NAME=REGISTRY_KEY]",
        ] as [String: Any]
    }

    /// Writes the practice's file and leaves it uncommitted: the user reads the diff and
    /// accepts it (DECISIONS 19). No version exists until then.
    func updatePractice(_ ref: String, code: String, project: String?) async throws -> Any {
        guard ref.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else {
            throw ToolError(description: "ref is service/name or chains/name")
        }
        let practice = Practice(ref: ref)
        let file = try store.writeDraft(code, for: practice, project: project)
        return ["written": true, "file": file.path, "pending": true,
                "current_version": try await store.versions(of: practice).count,
                "note": "Left uncommitted: it becomes a version when the user accepts it (practicesctl pending / accept). Keep the marker of the version you copied until then."] as [String: Any]
    }

    /// Fills a gap directly; an existing meaning is not overwritten (it is returned instead).
    func describeField(service: String, path: String, meaning: String, values: [String: String], from: String?) async throws -> Any {
        var fields = registry.fields(of: service)
        if let i = fields.firstIndex(where: { $0.path == path }) {
            if let existing = fields[i].meaning, !existing.isEmpty {
                return ["written": false, "reason": "already described; not overwritten", "meaning": existing]
            }
            fields[i].meaning = meaning
            if !values.isEmpty { fields[i].values = values }
            fields[i].from = (fields[i].from ?? []) + [from ?? origin]
        } else {
            fields.append(FieldDoc(path: path, meaning: meaning, values: values.isEmpty ? nil : values, from: [from ?? origin]))
            fields.sort { $0.path < $1.path }
        }
        // Its own file only: an unreviewed practice edit beside it must not be committed with it.
        try await registry.commit("\(service): describe \(path) (agent, \(origin))", [try registry.saveFields(fields, of: service)])
        return ["written": true]
    }

    func addNote(service: String, text: String) async throws -> Any {
        var notes = registry.notes(of: service) ?? ""
        if !notes.isEmpty && !notes.hasSuffix("\n") { notes += "\n" }
        let project = (origin as NSString).lastPathComponent
        notes += "- \(text.trimmingCharacters(in: .whitespacesAndNewlines)) _(агент, \(project), \(Date().formatted(date: .numeric, time: .omitted)))_\n"
        try await registry.commit("\(service): note from agent (\(origin))", [try registry.saveNotes(notes, of: service)])
        return ["written": true]
    }

    static func docstring(of code: String) -> String? {
        guard let range = code.range(of: #"\"\"\"([\s\S]*?)\"\"\""#, options: .regularExpression) else { return nil }
        return code[range].dropFirst(3).dropLast(3).split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value) || value is String || value is NSNumber,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
        else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Tool schemas

    static func tool(_ name: String, _ description: String, _ properties: [String: [String: Any]] = [:], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any]]
    }

    static var tools: [[String: Any]] { [
        tool("list_projects", "Projects of every space, parents before their children: what each is, its parent and children, its repositories with roles, ids of its services."),
        tool("get_project", "One project: its parent and children, repositories (role, clone URL, where the local clone is), folders, hosts (the servers it is deployed on: name, hint), services, chains. A parent project may have no repositories of its own.",
             ["id": ["type": "string"]], required: ["id"]),
        tool("list_services", "Services (compose services and external systems): kind, project, repository, other names, environments, guards, names of their keys and whether each has a value. Never values.",
             ["project": ["type": "string", "description": "only this project's services"]]),
        tool("get_service", "One service: its role in the data flow (role_inferred: not set in the card, inferred from kind and links), endpoints, conditions to know before the first request (e.g. a VPN), links in both directions (whom it calls, who calls it), keys, guards, notes (pitfalls), documents, dictionary of fields, practices.",
             ["id": ["type": "string"]], required: ["id"]),
        tool("get_conventions", "Личные соглашения пространства: как устроены репозитории (модули, compose, env, порты, задачи IDE, локальные домены) и файлы-шаблоны. Читать перед созданием проекта/сервиса или правкой окружения.",
             ["space": ["type": "string", "description": "id пространства"]], required: ["space"]),
        tool("list_practices", "Practices (run() functions) and chains, with a one-line summary and their last run.",
             ["service": ["type": "string", "description": "only this service's practices"]]),
        tool("get_practice", "A practice's code to copy (first line marks the copy — keep it), the env variable names it reads, conditions of its services, practices it uses, fields of its result, history.",
             ["ref": ["type": "string", "description": "service/name or chains/name"],
              "version": ["type": "integer", "description": "defaults to the latest"]], required: ["ref"]),
        tool("search", "Search by meaning: services by id, name, kind, alias or description (`services`), a field (e.g. acc_motion) in the service dictionaries, practices whose result has it, documents, notes and practice code.",
             ["query": ["type": "string"]], required: ["query"]),
        tool("run_practice", "Run a practice with the credentials of its services and get the result: shape, first rows, fields, steps of a chain, timing. Fails with the condition's hint when a condition does not hold; a failed run comes with `conditions` — the declared, unchecked conditions of its services (an authorisation, a network) and their hints.",
             ["ref": ["type": "string"],
              "params": ["type": "object", "description": "arguments of run(), as JSON values or strings"],
              "envs": ["type": "object", "description": "environment per service, e.g. {\"kafka\": \"dev\"}"],
              "rows": ["type": "integer", "description": "rows to return, default 20, max 200"]], required: ["ref"]),
        tool("env_names", "Names of the environment variables a set of services provides (and which have no value), and the command that runs a program with them.",
             ["refs": ["type": "array", "items": ["type": "string"], "description": "service or service@env"]], required: ["refs"]),
        tool("list_copies", "Copies of practices found under the search roots by their marker line: current, outdated, or modified in the project and not sent back.",
             ["ref": ["type": "string"]]),
        tool("update_practice", "Send a changed or new practice. The file is written and left uncommitted: the user reviews the diff and accepts it; until then there is no new version.",
             ["ref": ["type": "string", "description": "service/name or chains/name"],
              "code": ["type": "string", "description": "the whole file of the practice"],
              "project": ["type": "string", "description": "for a new chain: the project it belongs to"]],
             required: ["ref", "code"]),
        tool("add_link", "Record that one service calls another: kept at the caller, left uncommitted for the user to accept.",
             ["from": ["type": "string", "description": "the calling service"],
              "to": ["type": "string", "description": "the service it calls"],
              "endpoint": ["type": "string", "description": "an endpoint id of the called service"],
              "env": ["type": "string"],
              "via": ["type": "string", "enum": Link.vias],
              "what": ["type": "string", "description": "a topic, a table, a path"],
              "access": ["type": "string", "enum": Link.accesses],
              "why": ["type": "string"],
              "practice": ["type": "string", "description": "the practice that does this call, service/name"],
              "names": ["type": "object", "description": "the caller's variable → the called service's key"],
              "file": ["type": "string", "description": "the env file in the caller's repository"],
              "origin": ["type": "string", "description": "code:<file> where you saw the call (what an agent passes), manual, or derived:<file it was derived from>"]],
             required: ["from", "to"]),
        tool("reject_link", "Отклонить связь: вы проверили по коду, что выведенная сканером связь ложна (сервис не строит этого клиента, переменная пришла из общего env-файла). Не удаляйте её — запишите сюда: она уходит из links.yaml в rejected.yaml вызывающего с причиной, и сканер больше её не предлагает. Ключ — to + via (без via — любая) + для via: topic ещё what (топик). Правка остаётся незакоммиченной, пользователь принимает её сам.",
             ["from": ["type": "string", "description": "вызывающий сервис"],
              "to": ["type": "string", "description": "сервис, которого он на самом деле не вызывает"],
              "via": ["type": "string", "enum": Link.vias, "description": "без via отклоняются все пути к to"],
              "what": ["type": "string", "description": "топик, для via: topic"],
              "why": ["type": "string", "description": "одна строка: что в коде показывает, что связи нет (файл:строка)"],
              "origin": ["type": "string", "description": "code:<файл, где проверено>; по умолчанию manual"]],
             required: ["from", "to", "why"]),
        tool("scan_links", "What the files of a project's or a repository's local clones say and the catalogue may not: compose services without a card, links implied by URLs, DSNs and topic variables in compose and example env files (new, already recorded, or derived earlier and gone), addresses that match no service, shared external networks. Reads only; nothing is written.",
             ["target": ["type": "string", "description": "a project id or a repository address"]], required: ["target"]),
        tool("describe_field", "Write what a field of a service's results means (and its values). Fills a missing description; an existing one is not overwritten.",
             ["service": ["type": "string"], "path": ["type": "string", "description": "e.g. extra.acc_motion"],
              "meaning": ["type": "string"], "values": ["type": "object", "description": "value → meaning"],
              "from": ["type": "string", "description": "where you learned it: a file or doc"]],
             required: ["service", "path", "meaning"]),
        tool("add_note", "Add a pitfall or a finding to a service's notes.",
             ["service": ["type": "string"], "text": ["type": "string"]], required: ["service", "text"]),
        tool("setup_status", "Настроена ли эта машина: корни клонов (local.yaml) с числом найденных клонов, пространства с путём, веткой и незакоммиченными, для Claude Code, Codex и Cursor — найден ли, зарегистрирован ли MCP, блок инструкций absent/current/outdated(vN); клоны проектов, где блок есть. Ничего не меняет. Если commandInstalled=false: \(Setup.installHint)."),
        tool("setup_agents", "Настроить агентов на этой машине: зарегистрировать MCP-сервер practices и записать блок инструкций: scope global — в глобальные ~/.claude/CLAUDE.md / ~/.codex/AGENTS.md найденных инструментов, scope projects — в CLAUDE.md и AGENTS.md каждого клона проектов каталога (MCP регистрируется глобально в обоих случаях); с project — только блок в клоны этого проекта. Куда писать инструкции — глобально или в каждый проект — спросите пользователя, прежде чем вызывать. Возвращает, что записано: target, file, state.",
             ["scope": ["type": "string", "enum": InstructionScope.allCases.map(\.rawValue), "description": "global или projects — выбор пользователя"],
              "tools": ["type": "array", "items": ["type": "string", "enum": AgentTool.allCases.map(\.rawValue)], "description": "по умолчанию все найденные"],
              "mcp": ["type": "boolean", "description": "регистрировать MCP, по умолчанию да"],
              "instructions": ["type": "boolean", "description": "писать блок инструкций, по умолчанию да"],
              "project": ["type": "string", "description": "id проекта: блок в его клоны (scope тогда не важен)"]],
             required: ["scope"]),
    ] }
}
