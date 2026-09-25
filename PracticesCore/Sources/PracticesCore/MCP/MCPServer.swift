import Foundation

/// Practices for an agent working in a project (PLAN, stage 4): stdio MCP, one JSON-RPC
/// message per line. Values of secrets are never returned — the agent sees names of variables
/// and writes code against them (DECISIONS 4). Sources tagged `pii` return shapes, not rows.
public final class MCPServer: @unchecked Sendable {

    let registry = Registry()
    let secrets = SecretStore()
    lazy var store = PracticeStore(registry: registry)
    /// The directory the agent's project is in (the server's cwd), shown as a proposal's origin.
    let origin: String

    public init(origin: String = FileManager.default.currentDirectoryPath) { self.origin = origin }

    static let instructions = """
        Practices is the user's registry of data sources (databases, APIs, sockets), their \
        credentials and *practices*: small, tested Python functions `run(...)` that fetch or \
        process data from a source, and *chains* that combine them.

        Before writing code that reads one of these sources, `search` for the field or the \
        operation and `get_practice`: reuse the practice instead of writing a new client. Copy \
        its code as given — the first line `# practices: <ref>@v<N>` is how the copy is tracked; \
        keep it. Credentials: the code reads environment variables by name (`env_names` lists \
        them); values are never available to you. The project gets them by running under \
        `practicesctl run -- <command>`.

        When you change a copied practice in the project (a fix, a faster query), call \
        `propose_update` with the new code, *what and why*, and the parameters you tried it on. \
        Practices runs old and new versions and accepts the change itself when the result shape \
        and rows are the same and it is not slower; otherwise it waits for the user. Record \
        pitfalls with `add_note` and field meanings with `describe_field`.
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
                "serverInfo": ["name": "practices", "version": "0.4.0"],
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
        case "list_sources": return try listSources()
        case "get_source": return try getSource(try Self.string(args, "id"))
        case "list_practices": return try await listPractices(args["source"] as? String)
        case "get_practice": return try await getPractice(try Self.string(args, "ref"), version: args["version"] as? Int)
        case "search": return try encodable(Search.run(try Self.string(args, "query"), registry: registry, store: store))
        case "run_practice":
            return try await runPractice(try Self.string(args, "ref"), params: Self.params(args["params"]),
                                         envs: Self.params(args["envs"]), rows: args["rows"] as? Int ?? 20)
        case "env_names": return try envNames(args["refs"] as? [String])
        case "list_copies": return try encodable(await Copies.scan(store: store).filter { copy in
            (args["ref"] as? String).map { $0 == copy.ref } ?? true })
        case "propose_update":
            let proposal = try await ProposalReviewer(store: store).submit(
                ref: try Self.string(args, "ref"), code: try Self.string(args, "code"), why: try Self.string(args, "why"),
                params: args["params"].map(Self.params), origin: args["project"] as? String ?? origin)
            return [
                "status": proposal.status.rawValue, "verdict": proposal.verdict,
                "version": proposal.acceptedVersion as Any,
                "marker": proposal.acceptedVersion.map { Copies.markerLine(proposal.ref, version: $0) } as Any,
                "checks": proposal.checks.map { ["name": $0.name, "ok": $0.ok, "detail": $0.detail] },
                "id": proposal.id,
            ] as [String: Any]
        case "describe_field":
            return try await describeField(source: try Self.string(args, "source"), path: try Self.string(args, "path"),
                                           meaning: try Self.string(args, "meaning"),
                                           values: Self.params(args["values"]), from: args["from"] as? String)
        case "add_note":
            return try await addNote(source: try Self.string(args, "source"), text: try Self.string(args, "text"))
        default:
            throw ToolError(description: "unknown tool \(name)")
        }
    }

    func encodable<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
    }

    func listSources() throws -> Any {
        try registry.sources().map { source -> [String: Any] in
            let status = (try? secrets.status(source: source)) ?? [:]
            return [
                "id": source.id, "name": source.name, "kind": source.kind, "description": source.description ?? "",
                "tags": source.tags, "envs": source.envs, "guards": source.guards,
                "keys": source.keys.map { key in
                    ["name": key.name, "secret": key.secret,
                     "set": Dictionary(uniqueKeysWithValues: source.envs.map { ($0, status[$0]?.contains(key.name) == true) })] as [String: Any]
                },
                "practices": store.list(source: source.id).map(\.ref),
            ]
        }
    }

    func getSource(_ id: String) throws -> Any {
        guard var card = try (listSources() as? [[String: Any]])?.first(where: { $0["id"] as? String == id }) else {
            throw ToolError(description: "no source \(id)")
        }
        card["notes"] = registry.notes(of: id) ?? ""
        card["docs"] = try encodable(registry.docs(of: id))
        card["fields"] = try encodable(registry.fields(of: id))
        return card
    }

    func listPractices(_ source: String?) async throws -> Any {
        let list = source.map { store.list(source: $0) } ?? store.all()
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
        guard !versions.isEmpty else { throw ToolError(description: "no practice \(ref) (or it was never saved)") }
        let v = min(max(version ?? versions.count, 1), versions.count)
        let code = try await store.code(of: practice, at: versions[v - 1])
        let sources = store.sources(for: practice)
        let keyNames = sources.flatMap { id in ((try? registry.source(id))?.keys ?? []).map(\.name) }
        var schema: Any = []
        if let last = (try? RunsStore())?.runs(of: ref, limit: 20).first(where: { $0.ok && $0.schema != nil }),
           let data = last.schema?.data(using: .utf8) {
            schema = (try? JSONSerialization.jsonObject(with: data)) ?? []
        }
        return [
            "ref": ref, "version": v, "latest": versions.count,
            "code": Copies.stamped(code, ref: ref, version: v),
            "copy_note": "Keep the first line: it marks the copy so updates can find it.",
            "uses": store.dependencies(of: practice).map(\.ref),
            "sources": sources, "env_names": keyNames,
            "parameter_sets": try encodable(store.sets(of: practice)),
            "result_fields": schema,
            "history": versions.reversed().prefix(10).map { ["version": $0.number, "message": $0.message,
                                                             "date": ISO8601DateFormatter().string(from: $0.date)] },
        ] as [String: Any]
    }

    func runPractice(_ ref: String, params: [String: String], envs: [String: String], rows: Int) async throws -> Any {
        let practice = Practice(ref: ref)
        let result = try await PracticeRunner(store: store, secrets: secrets).run(practice, params: params, envs: envs)
        let sources = store.sources(for: practice)
        let pii = sources.contains { ((try? registry.source($0))?.tags ?? []).contains("pii") }
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
        if pii {
            out["note"] = "a source is tagged pii: rows are not returned, only their shape"
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

    func envNames(_ refs: [String]?) throws -> Any {
        var list = (refs ?? []).map(SourceRef.init(parsing:))
        if list.isEmpty, let found = ProjectManifest.find(from: URL(fileURLWithPath: origin)) { list = found.manifest.sources }
        guard !list.isEmpty else { throw ToolError(description: "give refs like [\"xkdb\", \"kafka@dev\"], or add practices.yaml to the project") }
        let resolved = try RunEnvironment.resolve(list, registry: registry, store: secrets)
        return [
            "variables": resolved.values.keys.sorted(),
            "missing": resolved.missing,
            "run_with": "practicesctl run \(list.map(\.description).joined(separator: " ")) -- <command>",
        ] as [String: Any]
    }

    /// Fills a gap directly; an existing meaning is not overwritten (it is returned instead).
    func describeField(source: String, path: String, meaning: String, values: [String: String], from: String?) async throws -> Any {
        guard (try? registry.source(source)) != nil else { throw ToolError(description: "no source \(source)") }
        var fields = registry.fields(of: source)
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
        try registry.saveFields(fields, of: source)
        try await registry.commit("\(source): describe \(path) (agent, \(origin))")
        return ["written": true]
    }

    func addNote(source: String, text: String) async throws -> Any {
        guard (try? registry.source(source)) != nil else { throw ToolError(description: "no source \(source)") }
        var notes = registry.notes(of: source) ?? ""
        if !notes.isEmpty && !notes.hasSuffix("\n") { notes += "\n" }
        let project = (origin as NSString).lastPathComponent
        notes += "- \(text.trimmingCharacters(in: .whitespacesAndNewlines)) _(агент, \(project), \(Date().formatted(date: .numeric, time: .omitted)))_\n"
        try registry.saveNotes(notes, of: source)
        try await registry.commit("\(source): note from agent (\(origin))")
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
        tool("list_sources", "Data sources in the registry: kind, environments, guards, names of their keys and whether each has a value. Never values."),
        tool("get_source", "One source: keys, guards, notes (pitfalls), documents, dictionary of fields, practices.",
             ["id": ["type": "string"]], required: ["id"]),
        tool("list_practices", "Practices (run() functions) and chains, with a one-line summary and their last run.",
             ["source": ["type": "string", "description": "only this source's practices"]]),
        tool("get_practice", "A practice's code to copy (first line marks the copy — keep it), the env variable names it reads, practices it uses, parameter sets, fields of its result, history.",
             ["ref": ["type": "string", "description": "source/name or chains/name"],
              "version": ["type": "integer", "description": "defaults to the latest"]], required: ["ref"]),
        tool("search", "Search by meaning: a field (e.g. acc_motion) in the source dictionaries, practices whose result has it, documents, notes and practice code.",
             ["query": ["type": "string"]], required: ["query"]),
        tool("run_practice", "Run a practice with the credentials of its sources and get the result: shape, first rows, fields, steps of a chain, timing.",
             ["ref": ["type": "string"],
              "params": ["type": "object", "description": "arguments of run(), as JSON values or strings"],
              "envs": ["type": "object", "description": "environment per source, e.g. {\"kafka\": \"dev\"}"],
              "rows": ["type": "integer", "description": "rows to return, default 20, max 200"]], required: ["ref"]),
        tool("env_names", "Names of the environment variables a set of sources provides (and which have no value), and the command that runs a program with them.",
             ["refs": ["type": "array", "items": ["type": "string"], "description": "source or source@env; defaults to the project's practices.yaml"]]),
        tool("list_copies", "Copies of practices found in ~/Projects by their marker line: current, outdated, or modified in the project and not sent back.",
             ["ref": ["type": "string"]]),
        tool("propose_update", "Send a changed practice back. Practices runs the old and new code on the saved parameter sets and yours, and accepts it itself when fields and rows match and it is not slower by more than 5%; otherwise the user reviews it. Returns the verdict and, if accepted, the new marker line to put in the copy.",
             ["ref": ["type": "string"], "code": ["type": "string", "description": "the whole new file of the practice"],
              "why": ["type": "string", "description": "what changed and why, for the review"],
              "params": ["type": "object", "description": "parameters you tried it on"],
              "project": ["type": "string", "description": "project path; defaults to the server's working directory"]],
             required: ["ref", "code", "why"]),
        tool("describe_field", "Write what a field of a source's results means (and its values). Fills a missing description; an existing one is not overwritten.",
             ["source": ["type": "string"], "path": ["type": "string", "description": "e.g. extra.acc_motion"],
              "meaning": ["type": "string"], "values": ["type": "object", "description": "value → meaning"],
              "from": ["type": "string", "description": "where you learned it: a file or doc"]],
             required: ["source", "path", "meaning"]),
        tool("add_note", "Add a pitfall or a finding to a source's notes.",
             ["source": ["type": "string"], "text": ["type": "string"]], required: ["source", "text"]),
    ] }
}
