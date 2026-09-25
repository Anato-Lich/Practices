import Foundation
import PracticesCore

// practicesctl — the core without the app. Every monitor feature is reachable from here
// first (DECISIONS 6), so it can be checked in a terminal before any UI exists for it.

let usage = """
    usage: practicesctl <command> [--json]

      ports         occupied TCP ports and who holds them
      containers    containers, failed ones first
      conflicts     ports compose files in ~/Projects want that something else holds
                    (--all: also projects that would collide with each other)
      watch         print container incidents as they happen (Ctrl-C to stop)
      logs <name>   last 200 log lines of a container

    registry (~/.practices):
      sources                       sources, their environments and key status
      source <id>                   one source: targets, keys, guards, notes, docs, fields
      check [id…]                   preconditions and targets of sources (all by default)
      secrets set <id> <KEY> [--env e]    value read from stdin, never from arguments
      secrets unset <id> <KEY> [--env e]
      import connectors [path]      the six sources of ~/Projects/Connectors and its .env
      env [ref…]                    names of the variables `run` would set (no values)
      run [ref…] -- <command…>      run a command with the sources' values in its environment;
                                    without refs, the nearest practices.yaml decides
      doctor                        .env files and plain text in ~/Projects against the registry

      ref = <source>[@<env>]

    practices:
      practices [source]            practices and chains
      sig <practice>                parameters of a practice's run()
      try <practice> [k=v…] [--env source=env…] [--rows N]
                                    run it and print the result (a table, a tree or text)
      runs <practice>               its run history: version, time, rows
      search <text>                 fields, practices whose result has it, docs, code

      practice = <source>/<name> | chains/<name>
    """

let args = Array(CommandLine.arguments.dropFirst())
let json = args.contains("--json")
let positional = args.filter { !$0.hasPrefix("--") }

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    print(String(decoding: try! encoder.encode(value), as: UTF8.self))
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

func home(_ path: String?) -> String {
    guard let path else { return "" }
    let h = NSHomeDirectory()
    return path.hasPrefix(h) ? "~" + path.dropFirst(h.count) : path
}

switch positional.first {
case "ports":
    let snapshot = await Monitor.snapshot()
    if json { printJSON(snapshot.ports); break }
    let contested = snapshot.contestedPorts
    for entry in snapshot.ports {
        let kind: String
        switch entry.owner {
        case .container(let c): kind = "container \(c.name)"
        case .process(let pid, let command): kind = "\(command) (\(pid))"
        }
        let flag = contested.contains(entry.port) ? "  ⚠ shared" : ""
        print(pad(String(entry.port), 7) + pad(entry.address, 12) + pad(kind, 44)
              + (entry.project.map { "project: \($0)" } ?? home(entry.projectDir)) + flag)
    }
    if let error = snapshot.dockerError { print("\ndocker: \(error)") }

case "containers":
    let snapshot = await Monitor.snapshot()
    guard let containers = snapshot.containers else {
        print("docker: \(snapshot.dockerError ?? "no answer")"); exit(1)
    }
    if json { printJSON(containers); break }
    print("context: \(snapshot.dockerContext ?? "?")\n")
    let failed = Set(snapshot.failedContainers.map(\.id))
    let ordered = containers.sorted {
        (failed.contains($0.id) ? 0 : $0.isRunning ? 1 : 2, $0.name)
            < (failed.contains($1.id) ? 0 : $1.isRunning ? 1 : 2, $1.name)
    }
    for c in ordered {
        let mark = failed.contains(c.id) ? "✗" : c.isRunning ? "●" : "○"
        let ports = c.ports.map { "\($0.hostPort)→\($0.containerPort)" }.joined(separator: " ")
        print("\(mark) " + pad(c.name, 36) + pad(c.status, 34) + pad(c.composeProject ?? "", 20) + ports)
    }

case "conflicts":
    async let scanTask = ComposeScanner.scan()
    let snapshot = await Monitor.snapshot()
    let scan = await scanTask
    let conflicts = PortConflicts.conflicts(claims: scan.claims, snapshot: snapshot)
    if json { printJSON(conflicts); break }
    print("\(scan.claims.count) published ports in compose files, \(conflicts.count) taken by someone else\n")
    for c in conflicts {
        let holders = c.holders.map { h in "\(h.ownerName)" + (h.project.map { " (\($0))" } ?? "") }
        print(pad(String(c.claim.hostPort), 7) + pad("\(c.claim.project) / \(c.claim.service)", 44)
              + "taken by " + holders.joined(separator: ", "))
        if !c.runningOn.isEmpty {
            print(String(repeating: " ", count: 7) + "runs remapped on " + c.runningOn.map(String.init).joined(separator: ", "))
        }
        print(String(repeating: " ", count: 7) + "OrbStack: " + c.claim.orbURL)
    }
    if args.contains("--all") {
        let collisions = PortConflicts.collisions(claims: scan.claims)
        if !collisions.isEmpty { print("\nwould collide if started together:") }
        for c in collisions {
            print(pad(String(c.hostPort), 7) + c.claims.map { "\($0.project)/\($0.service)" }.joined(separator: "  ·  "))
        }
        if !scan.unresolved.isEmpty { print("\nnot resolved:") }
        for (file, reason) in scan.unresolved.sorted(by: { $0.key < $1.key }) {
            print("  " + home(file) + "\n      " + reason)
        }
    }

case "watch":
    setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered, so a pipe sees each incident at once
    print("watching container events (Ctrl-C to stop)…")
    for await incident in DockerEvents.incidents() {
        if json { printJSON(incident); continue }
        let time = incident.date.formatted(date: .omitted, time: .standard)
        let code = incident.exitCode.map { " exit \($0)" } ?? ""
        print("\(time)  \(incident.kind.rawValue)  \(incident.name)\(code)"
              + (incident.composeProject.map { "  [\($0)]" } ?? ""))
    }

case "logs":
    guard positional.count > 1 else { print(usage); exit(2) }
    do { print(try await Docker.logs(positional[1])) } catch { print(error); exit(1) }

case "sources":
    let registry = Registry(), store = SecretStore()
    let sources = (try? registry.sources()) ?? []
    if json { printJSON(sources); break }
    if sources.isEmpty { print("registry is empty — try `practicesctl import connectors`"); break }
    for source in sources {
        let status = (try? store.status(source: source)) ?? [:]
        let envs = source.envs.map { env in "\(env) \(status[env]?.count ?? 0)/\(source.keys.count)" }
        print(pad(source.id, 14) + pad(source.name, 26) + pad(source.kind, 12) + envs.joined(separator: "  "))
    }

case "source":
    guard positional.count > 1 else { print(usage); exit(2) }
    let registry = Registry(), store = SecretStore()
    guard let source = try? registry.source(positional[1]) else { print("no source \(positional[1])"); exit(1) }
    if json { printJSON(source); break }
    print("\(source.name)  [\(source.kind)]  \(source.tags.joined(separator: ", "))")
    if let d = source.description { print(d) }
    let status = (try? store.status(source: source)) ?? [:]
    print("\nkeys" + source.envs.map { "  " + $0 }.joined())
    for key in source.keys {
        let marks = source.envs.map { status[$0]?.contains(key.name) == true ? "  set" : "  —  " }
        print("  " + pad(key.name + (key.secret ? " *" : ""), 30) + marks.joined())
    }
    if !source.targets.isEmpty {
        print("\ntargets")
        for t in source.targets { print("  " + pad(t.id, 12) + (t.label ?? "")) }
    }
    if !source.guards.isEmpty { print("\nguards"); source.guards.forEach { print("  · " + $0) } }
    if let notes = registry.notes(of: source.id), !notes.isEmpty { print("\nnotes\n" + notes) }
    let docs = registry.docs(of: source.id)
    if !docs.isEmpty { print("docs"); docs.forEach { print("  [\($0.kind.rawValue)] \($0.title)" + ($0.section.map { " § \($0)" } ?? "")) } }
    let fields = registry.fields(of: source.id)
    if !fields.isEmpty { print("\nfields: \(fields.count), described \(fields.filter { $0.meaning != nil }.count)") }

case "check":
    let registry = Registry(), store = SecretStore()
    var targets: [(Source, String)] = []
    let refs = positional.dropFirst().map(SourceRef.init(parsing:))
    let all = (try? registry.sources()) ?? []
    for source in all where refs.isEmpty || refs.contains(where: { $0.source == source.id }) {
        let wanted = refs.first { $0.source == source.id }?.env
        for env in source.envs where wanted == nil || wanted == env { targets.append((source, env)) }
    }
    var results: [CheckResult] = []
    await withTaskGroup(of: [CheckResult].self) { group in
        for (source, env) in targets {
            group.addTask {
                let values = (try? store.values(source: source.id, env: env)) ?? [:]
                var out = await Checks.check(source, env: env, values: values)
                for failure in await Checks.unmet(source, env: env, values: values) {
                    out.insert(CheckResult(source: source.id, env: env, target: "requires", ok: false, millis: nil, message: failure), at: 0)
                }
                return out
            }
        }
        for await r in group { results += r }
    }
    results.sort { ($0.source, $0.env) < ($1.source, $1.env) }
    if json { printJSON(results); break }
    for r in results {
        let mark = r.ok ? "●" : "✗"
        print("\(mark) " + pad("\(r.source)@\(r.env)", 20) + pad(r.target, 12)
              + pad(r.millis.map { "\($0) ms" } ?? "", 9) + (r.message ?? ""))
    }

case "secrets":
    let store = SecretStore(), registry = Registry()
    guard positional.count >= 4, ["set", "unset"].contains(positional[1]) else { print(usage); exit(2) }
    let id = positional[2], key = positional[3]
    guard let source = try? registry.source(id) else { print("no source \(id)"); exit(1) }
    let env = args.firstIndex(of: "--env").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? source.defaultEnv
    guard source.envs.contains(env) else { print("\(id) has environments " + source.envs.joined(separator: ", ")); exit(1) }
    if positional[1] == "unset" {
        try store.remove(key: key, source: id, env: env)
        print("\(id)@\(env) \(key): unset")
        break
    }
    // From stdin, so the value stays out of shell history and `ps` (PLAN, threat model).
    var value: String?
    if isatty(0) != 0 {
        var buffer = [CChar](repeating: 0, count: 4096)
        value = readpassphrase("\(key) for \(id)@\(env): ", &buffer, buffer.count, 0).map { String(cString: $0) }
    } else {
        value = readLine(strippingNewline: true)
    }
    guard let value, !value.isEmpty else { print("empty value, nothing stored"); exit(1) }
    try store.set(value, key: key, source: id, env: env)
    if !source.keys.contains(where: { $0.name == key }) {
        var updated = source
        updated.keys.append(Source.Key(name: key))
        try registry.save(updated)
        try await registry.commit("\(id): declare \(key)")
    }
    print("\(id)@\(env) \(key): set")

case "import":
    guard positional.count > 1, positional[1] == "connectors" else { print(usage); exit(2) }
    let path = positional.count > 2 ? positional[2] : NSHomeDirectory() + "/Projects/Connectors"
    let summary = try await ConnectorsImport.run(connectors: URL(fileURLWithPath: path))
    print("sources: " + summary.sources.joined(separator: ", "))
    print("values imported: \(summary.valuesImported)")
    if !summary.unassigned.isEmpty { print("keys no source claims: " + summary.unassigned.joined(separator: ", ")) }
    print("registry: \(PracticesHome.registry.path)")

case "env", "run":
    let separator = args.firstIndex(of: "--")
    let before = separator.map { Array(args[..<$0]) } ?? args
    let refArgs = before.dropFirst().filter { !$0.hasPrefix("--") }
    var refs = refArgs.map(SourceRef.init(parsing:))
    if refs.isEmpty {
        guard let found = ProjectManifest.find(from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) else {
            print("no sources given and no \(ProjectManifest.fileName) here or above"); exit(2)
        }
        refs = found.manifest.sources
        FileHandle.standardError.write(Data("practices: \(found.url.path)\n".utf8))
    }
    let resolved: RunEnvironment.Resolved
    do { resolved = try RunEnvironment.resolve(refs) } catch { print("practices: \(error)"); exit(1) }
    for (ref, keys) in resolved.missing.sorted(by: { $0.key < $1.key }) {
        FileHandle.standardError.write(Data("practices: \(ref) has no value for \(keys.joined(separator: ", "))\n".utf8))
    }
    if positional.first == "env" {
        for key in resolved.values.keys.sorted() { print(key) }
        break
    }
    guard let separator, separator + 1 < args.count else { print("usage: practicesctl run [ref…] -- <command…>"); exit(2) }
    // Preconditions first: a sentence now instead of a timeout later.
    var unmet: [String] = []
    for (source, env) in resolved.sources {
        let values = (try? SecretStore().values(source: source.id, env: env)) ?? [:]
        unmet += await Checks.unmet(source, env: env, values: values)
    }
    if !unmet.isEmpty {
        unmet.forEach { FileHandle.standardError.write(Data("practices: \($0)\n".utf8)) }
        exit(1)
    }
    for (key, value) in resolved.values { setenv(key, value, 1) }
    let command = Array(args[(separator + 1)...])
    let cArgs = command.map { strdup($0) } + [nil]
    execvp(command[0], cArgs)
    print("practices: cannot run \(command[0]): \(String(cString: strerror(errno)))")
    exit(127)

case "doctor":
    let findings = try await Doctor.run()
    if json { printJSON(findings); break }
    if findings.isEmpty { print("nothing to report"); break }
    for f in findings {
        switch f.kind {
        case .leak:
            print("LEAK      \(home(f.path))\n          registry secrets in plain text: \(f.keys.joined(separator: ", "))")
        case .drift:
            print("DRIFT     \(home(f.path))\n          differs from \(f.related[0]): \(f.keys.joined(separator: ", "))")
        case .shared:
            print("SHARED    \(f.keys.joined(separator: ", ")) — same value in:\n          "
                  + ([f.path] + f.related).map(home).joined(separator: "\n          "))
        case .duplicate:
            print("DUPLICATE \(home(f.path))\n          all \(f.keys.count) keys match \(f.related[0]) — replaceable by `practicesctl run`")
        }
    }

case "practices":
    let store = PracticeStore()
    let list = positional.count > 1 ? store.list(source: positional[1]) : store.all()
    if json { printJSON(list.map(\.ref)); break }
    let runs = try? RunsStore()
    for p in list {
        let last = runs?.runs(of: p.ref, limit: 1).first
        let tail = last.map { "  last: \($0.ok ? "ok" : "failed") \($0.millis) ms" + ($0.rows.map { ", \($0) rows" } ?? "") } ?? ""
        print(pad(p.ref, 34) + tail)
    }

case "sig":
    guard positional.count > 1 else { print(usage); exit(2) }
    let sig = try await PracticeRunner().signature(of: Practice(ref: positional[1]))
    if json { printJSON(sig); break }
    guard sig.ok else { print(sig.error ?? "failed"); exit(1) }
    if let doc = sig.doc, !doc.isEmpty { print(doc + "\n") }
    for p in sig.params ?? [] {
        print("  " + pad(p.name, 18) + pad(p.annotation ?? "", 22) + (p.required ? "required" : "= \(p.default ?? "")"))
    }

case "try":
    guard positional.count > 1 else { print(usage); exit(2) }
    let practice = Practice(ref: positional[1])
    var params: [String: String] = [:]
    var envs: [String: String] = [:]
    var maxRows = 20
    var i = 2
    let rest = Array(CommandLine.arguments.dropFirst())
    while i < rest.count {
        let a = rest[i]
        if a == "--env", i + 1 < rest.count {
            let kv = rest[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { envs[kv[0]] = kv[1] }
            i += 2; continue
        }
        if a == "--rows", i + 1 < rest.count { maxRows = Int(rest[i + 1]) ?? maxRows; i += 2; continue }
        if a == "--json" { i += 1; continue }
        let kv = a.split(separator: "=", maxSplits: 1).map(String.init)
        if kv.count == 2 { params[kv[0]] = kv[1] }
        i += 1
    }
    let result = try await PracticeRunner().run(practice, params: params, envs: envs)
    if json { printJSON(result); break }
    let envText = result.envs.sorted { $0.key < $1.key }.map { "\($0.key)@\($0.value)" }.joined(separator: " ")
    print("\(practice.ref)" + (result.version.map { " v\($0)" } ?? "") + "  ·  \(envText)  ·  \(result.ms) ms"
          + (result.total.map { "  ·  \($0) rows" } ?? "") + (result.bytes.map { "  ·  \($0 / 1024) KB" } ?? ""))
    for step in result.steps {
        print("  step " + pad(step.ref, 30) + pad("\(step.ms) ms", 10) + (step.ok ? (step.total.map { "\($0) rows" } ?? "") : "failed: \(step.error ?? "")"))
    }
    if !result.secretsUpdated.isEmpty { print("  stored rotated: " + result.secretsUpdated.joined(separator: ", ")) }
    if !result.stdout.isEmpty { print("\n-- stdout\n" + result.stdout) }
    guard result.ok else {
        print("\nfailed: \(result.error ?? "")\n" + (result.traceback ?? "") + (result.stderr.isEmpty ? "" : "\n-- stderr\n" + result.stderr))
        exit(1)
    }
    print("")
    switch result.shape {
    case "table":
        let columns = result.columns ?? []
        let rows = (result.rows ?? []).prefix(maxRows).map { $0.map { String($0.cellText.prefix(40)) } }
        let widths = columns.indices.map { c in min(40, max(columns[c].count, rows.map { c < $0.count ? $0[c].count : 0 }.max() ?? 0)) }
        print(columns.enumerated().map { pad($0.element, widths[$0.offset] + 2) }.joined())
        for row in rows { print(row.enumerated().map { pad($0.element, widths[$0.offset] + 2) }.joined()) }
        if let total = result.total, total > rows.count { print("… \(total - rows.count) more") }
    case "tree":
        if let tree = result.tree {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(tree), as: UTF8.self).split(separator: "\n").prefix(60).joined(separator: "\n"))
        }
    case "text": print(result.text ?? "")
    default: print("(no result)")
    }
    if let schema = result.schema, !schema.isEmpty {
        print("\nfields: " + schema.prefix(30).map { "\($0.path):\($0.type)" }.joined(separator: "  "))
    }

case "runs":
    guard positional.count > 1, let runs = try? RunsStore() else { print(usage); exit(2) }
    let list = runs.runs(of: positional[1])
    if json { printJSON(list); break }
    for r in list {
        print(r.started.formatted(date: .abbreviated, time: .shortened) + "  " + pad(r.version.map { "v\($0)" } ?? "", 5)
              + pad(r.ok ? "ok" : "failed", 8) + pad("\(r.millis) ms", 10) + pad(r.rows.map { "\($0) rows" } ?? "", 12)
              + r.env + (r.error.map { "  " + $0.prefix(80) } ?? ""))
    }

case "search":
    guard positional.count > 1 else { print(usage); exit(2) }
    let results = Search.run(positional.dropFirst().joined(separator: " "))
    if json { printJSON(results); break }
    if results.isEmpty { print("nothing found"); break }
    if !results.fields.isEmpty { print("FIELDS") }
    for hit in results.fields {
        var line = "  " + pad("\(hit.source) · \(hit.field.path)", 40) + pad(hit.field.type ?? "", 8)
        line += hit.field.meaning ?? "(no description)"
        print(line)
        if let values = hit.field.values { print("      " + values.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: " · ")) }
    }
    if !results.results.isEmpty { print("\nIN RESULTS") }
    for hit in results.results {
        print("  " + pad(hit.practice, 34) + pad(hit.path, 22) + "\(hit.present)/\(hit.seen) rows"
              + (hit.viaStep.map { "  via \($0)" } ?? ""))
    }
    if !results.docs.isEmpty { print("\nDOCS") }
    for hit in results.docs { print("  " + pad((hit.source ?? "") + " · " + hit.title, 34) + hit.excerpt) }
    if !results.code.isEmpty { print("\nCODE") }
    for hit in results.code { print("  " + pad(hit.title, 34) + hit.excerpt) }

default:
    print(usage)
    exit(positional.isEmpty ? 0 : 2)
}
