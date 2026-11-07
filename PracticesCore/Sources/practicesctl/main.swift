import Foundation
import PracticesCore

// practicesctl — the core without the app. Every feature is reachable from here
// first (DECISIONS 6), so it can be checked in a terminal before any UI exists for it.

let usage = """
    usage: practicesctl <command> [--json]

    catalogue (~/.practices/spaces/<space>, one git repository per space):
      spaces                        spaces: path, branch, uncommitted (the catalogue is personal:
                                    each space is a local git repository, never shared)
      space add <id> [--name N] [--hosting host/owner …]
      projects [space]              the tree of projects with their repositories and services
      project <id>                  one project: repositories (role, local clone), services, chains
      project add <space>/<id> [--parent <project>] [--name N] [--description D]
      repos [--all]                 not assigned to any project: from gh / glab by the spaces'
                                    hosting, plus local clones (--all: ignored ones too)
      assign <repo> <project> [--role r]     repo = a remote address in any form
      unassign <repo>
      remove-project <id> [--keep-repos]   delete a project and its services; its repositories go to the
                                    space's ignore list unless --keep-repos (refused while it has child projects)
      ignore <repo> [--space id]    keep a repository out of `repos` (the space is the one whose
      unignore <repo> [--space id]  hosting lists it, unless given)
      services [project]            services, their environments and key status
      service <id>                  one service: endpoints, conditions, links, keys, notes, docs
      service add <id> --project <p> [--name N] [--kind k] [--description D] [--repo r]
                                    [--alias a …] [--env e …] [--key K …]
      links [service]               who calls whom (of one service: both directions)
      link add <from> <to> [--endpoint e] [--env e] [--via http|topic|db|network|build]
                                    [--what w] [--access read|write] [--why w] [--practice ref]
                                    [--file f] [--as VAR=KEY …] [--origin o] [--no-commit]
                                    --origin: manual (default), code:<file> where the call is seen
                                    (what agents pass); --no-commit leaves it for `accept`
      link reject <from> <to> [--via v] [--what topic] --why "…" [--origin o] [--no-commit]
                                    the link was checked and is false: it leaves links.yaml, goes to
                                    rejected.yaml, and `scan` no longer offers it (origin: manual,
                                    code:<file>, audit:<report>)
      link unreject <from> <to> [--via v] [--what topic] [--no-commit]
      conditions [space]            named conditions and who requires them
      condition add <space>/<id> --name N [--hint H] [--reachable TEMPLATE]
                                    TEMPLATE = host:port over the service's keys, e.g. '${PG_HOST}:${PG_PORT}'
      scan [project | repo]… [--write] [--all]   services and links the clones' compose files and
                                    example env files give, against the catalogue (default: every
                                    assigned clone); --write leaves the new ones uncommitted for
                                    `accept`; links refused before are counted, --all lists them
      pending                       uncommitted changes in the spaces (an agent's edits)
      accept [space [path…]] [--message m]   commit them: all, one space's, or the given files
      discard <space> <path…>       drop them: a new file is deleted, an edited one restored

    values and checks:
      check [ref…]                  endpoints and conditions of services (all by default)
      secrets set <id> <KEY> [--env e]    value read from stdin, never from arguments
      secrets unset <id> <KEY> [--env e]
      secrets import <id>@<env> [--from <.env>] KEY=THEIR_KEY | KEY:=value | KEY=env:<other env> …
                                    fill an environment (adding it if new); values are never printed
      env <ref…>                    names of the variables `run` would set (no values)
      run <ref…> -- <command…>      run a command with the services' values in its environment
      doctor                        .env files and plain text under the search roots against the registry
      connect <ref…> --to <file> [--project dir] [--as VAR=KEY…] [--only KEY,KEY]
                                    write services' values into a project's env file, once;
                                    refuses files git would commit (--force)

      ref = <service>[@<env>]

    practices:
      practices [service]           practices and chains
      sig <practice>                parameters of a practice's run()
      try <practice> [k=v…] [--env service=env…] [--rows N]
                                    run it and print the result (a table, a tree or text)
      runs <practice>               its run history: version, time, rows
      search <text>                 fields, practices whose result has it, docs, code
      copies [practice]             copies under the search roots found by their marker: current / outdated / modified

    this machine (~/.practices/local.yaml, agents' settings; never in git):
      roots                         folders where clones are looked for, with the clones found
      roots add <path>… | roots remove <path>
      setup status [--json]         roots, spaces, agents: MCP registered,
                                    instruction block absent / current / outdated, project clones with it
      setup roots <path>…           = roots add, for the first run
      setup agents --global | --projects [--tools claude,codex,cursor] [--no-mcp] [--no-instructions]
                                    register the MCP server for the tools found (~/.claude, ~/.codex,
                                    ~/.cursor) and write the instruction block: --global into
                                    ~/.claude/CLAUDE.md and ~/.codex/AGENTS.md, --projects into CLAUDE.md
                                    and AGENTS.md of every clone of the catalogue's projects;
                                    with neither, asks (in a terminal)
      setup agents --project <id>   the block into CLAUDE.md and AGENTS.md of the project's clones

    agent:
      mcp                           MCP server on stdin/stdout

      practice = <service>/<name> | chains/<name>
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

/// `--json` carries what yaml leaves to the path — the id, the space, the project, the caller —
/// beside the record's own fields.
struct Placed<T: Encodable>: Encodable {
    struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    let place: [String: String]
    let value: T

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
        var c = encoder.container(keyedBy: Key.self)
        for (key, text) in place { try c.encode(text, forKey: Key(stringValue: key)) }
    }
}

func placed(_ p: Project) -> Placed<Project> { Placed(place: ["id": p.id, "space": p.space], value: p) }
func placed(_ s: Service) -> Placed<Service> { Placed(place: ["space": s.space, "project": s.project], value: s) }
func placed(_ link: Link, from: String) -> Placed<Link> { Placed(place: ["from": from], value: link) }

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

func summary(_ lines: [EnvFiles.Line]) -> String {
    let counts = Dictionary(grouping: lines, by: \.state).mapValues(\.count)
    return [EnvFiles.State.same, .changed, .new, .missingValue].compactMap { state in
        counts[state].map { "\($0) \(state == .missingValue ? "without value" : state.rawValue)" }
    }.joined(separator: ", ")
}

/// `--name value` options of the catalogue commands (repeatable) and what is left of the
/// arguments after the command word; `--json`, `--all`, `--force` and `--write` take no value.
func parse(_ args: [String]) -> (rest: [String], options: [String: [String]]) {
    var rest: [String] = [], options: [String: [String]] = [:]
    var i = 0
    while i < args.count {
        let a = args[i]
        if ["--json", "--all", "--force", "--unassigned", "--write", "--no-commit", "--no-mcp", "--no-instructions", "--global", "--projects"].contains(a) { i += 1; continue }
        if a.hasPrefix("--"), i + 1 < args.count { options[a, default: []].append(args[i + 1]); i += 2; continue }
        rest.append(a); i += 1
    }
    return (rest, options)
}

func fail(_ message: String, _ code: Int32 = 1) -> Never {
    print(message)
    exit(code)
}

/// A repository given as an address in any form.
func repoID(_ text: String) -> RepoID {
    guard let id = RepoID(text) else { fail("not a repository address: \(text) (host/owner/name, or a clone URL)", 2) }
    return id
}

/// `xkeeper-pg/devices@prod  db x-keeper_devices.devices (read) — why`; for an incoming link
/// the other side is the caller and the endpoint is this service's.
func linkLine(_ other: String, _ l: Link, incoming: Bool = false) -> String {
    var line = other + (l.endpoint.map { incoming ? " (to \($0))" : "/\($0)" } ?? "") + (l.env.map { "@\($0)" } ?? "")
    let how = [l.via, l.what, l.access.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
    if !how.isEmpty { line = pad(line, 34) + how }
    return line + (l.why.map { " — \($0)" } ?? "")
}

func home(_ path: String?) -> String {
    guard let path else { return "" }
    let h = NSHomeDirectory()
    return path.hasPrefix(h) ? "~" + path.dropFirst(h.count) : path
}

/// `x-keeper  X-Keeper  main  2 uncommitted`
func spaceLine(_ s: SpaceState) -> String {
    pad(s.id, 16) + pad(s.name, 22) + pad(s.branch ?? (s.uncommitted == nil ? "no git" : "detached"), 10)
        + (s.uncommitted.map { "\($0) uncommitted" } ?? "")
}

switch positional.first {
case "spaces":
    let states: [SpaceState]
    do { states = try await Registry().spaceStates() } catch { fail("practices: \(error)") }
    if json { printJSON(states); break }
    if states.isEmpty { print("no spaces yet — `practicesctl space add <id>`"); break }
    for s in states { print(spaceLine(s)) }

case "space":
    let (rest, options) = parse(args)
    let registry = Registry()
    do {
        switch (rest.count > 1 ? rest[1] : "", rest.count) {
        case ("add", 3):
            let hosting = (options["--hosting"] ?? []).map { text -> Space.Hosting in
                let parts = text.split(separator: "/", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { fail("--hosting is host/owner, e.g. github.com/X-Keeper", 2) }
                return Space.Hosting(host: parts[0], owner: parts[1])
            }
            try await registry.add(Space(id: rest[2], name: options["--name"]?.last ?? rest[2], hosting: hosting))
            print("space \(rest[2]): \(home(registry.dir(ofSpace: rest[2]).path))")
        default: print(usage); exit(2)
        }
    } catch { fail("practices: \(error)") }

case "roots":
    let (rest, _) = parse(args)
    let registry = Registry()
    do {
        switch (rest.count > 1 ? rest[1] : "", rest.count) {
        case ("", 1):
            if registry.local.roots.isEmpty { print("no roots in local.yaml — looking in the default one") }
            for root in registry.searchRoots { print(pad(home(root), 40) + "  \(Repos.clones(roots: [root]).count) clones") }
        case ("add", 3...): for path in rest.dropFirst(2) { print("root \(try Registry().addRoot(path)) added") }
        case ("remove", 3): try registry.removeRoot(rest[2]); print("root \(rest[2]) removed")
        default: print(usage); exit(2)
        }
    } catch { fail("practices: \(error)") }

case "setup":
    let (rest, options) = parse(args)
    do {
        switch rest.count > 1 ? rest[1] : "" {
        case "status":
            let status = try await Setup.status()
            if json { printJSON(status); break }
            print("roots" + (status.defaultRoots ? " (none in local.yaml — the default; `practicesctl setup roots <path>…`)" : ""))
            for r in status.roots { print("  " + pad(home(r.path), 40) + "  " + (r.exists ? "\(r.clones) clones" : "missing")) }
            print("\nspaces" + (status.spaces.isEmpty ? " — none; `practicesctl space add <id>`" : ""))
            for s in status.spaces { print("  " + spaceLine(s)) }
            print("\nagents (MCP command \(home(status.command))" + (status.commandInstalled ? ")" : " — not installed: ./install.sh)"))
            for t in status.tools {
                print("  " + pad(t.tool.rawValue, 8) + (t.found ? pad("MCP " + (t.mcp ? "registered" : "not registered"), 22)
                      + (t.instructions.map { "instructions " + $0 } ?? "") : "not found"))
            }
            if !status.projectBlocks.isEmpty { print("\nproject clones with the block") }
            for b in status.projectBlocks { print("  " + pad(b.project, 24) + pad(home(b.clone) + "/" + b.file, 60) + b.state) }
        case "agents":
            if let project = options["--project"]?.last {
                try Setup.project(project).forEach { print(pad($0.target, 10) + pad($0.state, 12) + home($0.file)) }
                break
            }
            let tools = try options["--tools"]?.last.map { list in
                try list.split(separator: ",").map { name in
                    guard let tool = AgentTool(rawValue: String(name)) else { throw Registry.Failure("--tools is a list of claude, codex, cursor") }
                    return tool
                }
            }
            let scope: InstructionScope
            if args.contains("--global") != args.contains("--projects") {
                scope = args.contains("--global") ? .global : .projects
            } else if args.contains("--global") {
                fail("practices: --global or --projects, not both", 2)
            } else if isatty(0) != 0 {
                let n = try Setup.projectClones(registry: Registry()).count
                print("Куда записать инструкции агентам?\n  [1] глобально — ~/.claude/CLAUDE.md, ~/.codex/AGENTS.md\n  [2] в каждый проект — CLAUDE.md/AGENTS.md клонов (\(n) клонов)")
                print("> ", terminator: "")
                switch readLine()?.trimmingCharacters(in: .whitespaces) {
                case "1": scope = .global
                case "2": scope = .projects
                default: fail("practices: ответ 1 или 2", 2)
                }
            } else {
                fail("practices: укажите --global или --projects", 2)
            }
            try Setup.agents(tools: tools, mcp: !args.contains("--no-mcp"), instructions: !args.contains("--no-instructions"), scope: scope)
                .forEach { print(pad($0.target, 10) + pad($0.state, 12) + home($0.file)) }
        case "roots" where rest.count > 2:
            for path in rest.dropFirst(2) { print("root \(try Registry().addRoot(path)) added") }
        default: print(usage); exit(2)
        }
    } catch { fail("practices: \(error)") }

case "projects":
    let registry = Registry()
    let projects = try registry.projects(space: positional.count > 1 ? positional[1] : nil)
    if json { printJSON(projects.map(placed)); break }
    let services = try registry.services()
    for (p, depth) in Registry.tree(projects) {
        print(pad(String(repeating: "  ", count: depth) + (depth == 0 ? "\(p.space)/" : "") + p.id, 38) + pad(p.name, 26)
              + pad("\(p.repos.count) repos", 10) + "\(services.filter { $0.project == p.id }.count) services")
    }

case "project":
    let (rest, options) = parse(args)
    let registry = Registry()
    if rest.count == 3, rest[1] == "add" {
        // `<space>/<id>`; a bare id takes the space of its parent.
        let parts = rest[2].split(separator: "/", maxSplits: 1).map(String.init)
        let parent = options["--parent"]?.last
        guard let space = parts.count == 2 ? parts[0] : parent.flatMap({ try? registry.project($0).space }) else {
            fail("which space? project add <space>/<id>", 2)
        }
        do {
            try await registry.add(Project(id: parts.last!, space: space, name: options["--name"]?.last ?? parts.last!,
                                           parent: parent, description: options["--description"]?.last))
        } catch { fail("practices: \(error)") }
        print("project " + ([space] + registry.path(ofProject: parts.last!)).joined(separator: "/"))
        break
    }
    guard rest.count == 2 else { print(usage); exit(2) }
    let project: Project
    do { project = try registry.project(rest[1]) } catch { fail("\(error)") }
    if json { printJSON(placed(project)); break }
    print("\(project.name)  [" + ([project.space] + registry.path(ofProject: project.id)).joined(separator: "/") + "]")
    if let d = project.description { print(d) }
    let clones = Repos.clones(roots: registry.searchRoots)
    let children = try registry.projects(space: project.space).filter { $0.parent == project.id }.map(\.id)
    if !children.isEmpty { print("contains: " + children.joined(separator: ", ")) }
    if !project.repos.isEmpty { print("\nrepositories") }
    for r in project.repos {
        print("  " + pad(r.repo.description, 58) + pad(r.role ?? "", 12) + (clones[r.repo].map(home) ?? "not cloned"))
    }
    if !project.folders.isEmpty { print("\nfolders") }
    for f in project.folders { print("  " + pad(f.name, 58) + (registry.local.folders[f.name].map(home) ?? "no path in local.yaml")) }
    let services = try registry.services(project: project.id)
    if !services.isEmpty { print("\nservices") }
    for s in services { print("  " + pad(s.id, 26) + pad(s.kind, 12) + s.name) }
    let chains = PracticeStore(registry: registry).chains(project: project.id)
    if !chains.isEmpty { print("\nchains\n  " + chains.map(\.ref).joined(separator: "  ")) }

case "repos":
    let (repos, problems) = try await Repos.unassigned()
    let shown = repos.filter { args.contains("--all") || !$0.ignored }
    if json { printJSON(shown); break }
    // Columns as wide as their longest cell: addresses and subgroup names have no usual length.
    let rows = shown.map { r in
        [r.repo.description, r.lastActivity.map { $0.formatted(.iso8601.year().month().day()) } ?? "",
         r.suggestedProject.map { "→ \($0)?" } ?? "",
         [r.archived ? "archived" : nil, r.ignored ? "ignored" : nil, r.space == nil ? "local only" : nil].compactMap { $0 }.joined(separator: ", "),
         home(r.clone)]
    }
    let widths = (0..<5).map { column in (rows.map { $0[column].count }.max() ?? 0) + 2 }
    for row in rows {
        print(zip(row, widths).map { $1 > 2 ? pad($0, $1) : "" }.joined().trimmingCharacters(in: .whitespaces))
    }
    let hidden = repos.count - shown.count
    print("\n\(shown.count) not assigned" + (hidden > 0 ? " (\(hidden) ignored: --all)" : "") + " — `practicesctl assign <repo> <project>`")
    problems.forEach { print("could not list \($0)") }

case "assign":
    let (rest, options) = parse(args)
    guard rest.count == 3 else { print(usage); exit(2) }
    let repo = repoID(rest[1])
    do { try await Registry().assign(repo, to: rest[2], role: options["--role"]?.last) } catch { fail("practices: \(error)") }
    print("\(repo) → \(rest[2])")

case "unassign":
    guard positional.count == 2 else { print(usage); exit(2) }
    let repo = repoID(positional[1])
    guard let project = try await Registry().unassign(repo) else { fail("\(repo) is in no project") }
    print("\(repo) taken out of \(project)")

case "remove-project":
    guard positional.count == 2 else { print(usage); exit(2) }
    let id = positional[1], registry = Registry(), keep = args.contains("--keep-repos")
    let project: Project, services: Int, dangling: [(from: String, to: String)]
    do {
        project = try registry.project(id)
        services = try registry.services(project: id).count
        dangling = try await registry.remove(project: id, ignoreRepos: !keep)
    } catch { fail("practices: \(error)") }
    print("removed \(id): \(services) services; repos \(keep ? "kept unassigned" : "ignored"): " + project.repos.map(\.repo.description).joined(separator: ", "))
    dangling.forEach { print("dangling: \($0.from) → \($0.to)") }

case "ignore", "unignore":
    let (rest, options) = parse(args)
    guard rest.count == 2 else { print(usage); exit(2) }
    let repo = repoID(rest[1]), registry = Registry()
    // The space whose hosting lists the repository: its address starts with that host/owner.
    let owners = try registry.spaces().filter { space in
        space.hosting.contains { repo.description.hasPrefix("\($0.host)/\($0.owner)/".lowercased()) }
    }.map(\.id)
    guard let space = options["--space"]?.last ?? (owners.count == 1 ? owners[0] : nil) else {
        fail(owners.isEmpty ? "no space's hosting lists \(repo) — say which: --space <id>"
                            : "\(repo) is under the hosting of \(owners.joined(separator: ", ")) — say which: --space <id>", 2)
    }
    do { try await registry.ignore(repo, in: space, rest[0] == "ignore") } catch { fail("practices: \(error)") }
    print("\(space): \(repo) " + (rest[0] == "ignore" ? "ignored" : "not ignored any more"))

case "services":
    let registry = Registry(), store = SecretStore()
    let services = try registry.services(project: positional.count > 1 ? positional[1] : nil)
    if json { printJSON(services.map(placed)); break }
    if services.isEmpty { print("no services — `practicesctl service add <id> --project <project>`"); break }
    for service in services {
        let status = (try? store.status(service: service)) ?? [:]
        let envs = service.envs.map { env in "\(env) \(status[env]?.count ?? 0)/\(service.keys.count)" }
        print(pad(service.id, 22) + pad(service.project, 20) + pad(service.name, 26) + pad(service.kind, 12) + envs.joined(separator: "  "))
    }

case "service":
    let (rest, options) = parse(args)
    let registry = Registry(), store = SecretStore()
    if rest.count == 3, rest[1] == "add" {
        guard let project = options["--project"]?.last else { fail("which project? --project <id>", 2) }
        let service = Service(id: rest[2], name: options["--name"]?.last ?? rest[2], kind: options["--kind"]?.last ?? "other",
                              description: options["--description"]?.last, repo: options["--repo"]?.last.map(repoID),
                              aliases: options["--alias"] ?? [], envs: options["--env"] ?? ["prod"],
                              keys: (options["--key"] ?? []).map { Service.Key(name: $0) })
        do { try await registry.add(service, to: project) } catch { fail("practices: \(error)") }
        print("service \(rest[2]) in \(project): \(home(registry.dir(of: rest[2])?.path))")
        break
    }
    guard rest.count == 2 else { print(usage); exit(2) }
    let service: Service
    do { service = try registry.service(rest[1]) } catch { fail("\(error)") }
    if json { printJSON(placed(service)); break }
    print("\(service.name)  [\(service.kind)]  " + ([service.space] + registry.path(ofProject: service.project) + [service.id]).joined(separator: "/")
          + "  \(service.tags.joined(separator: ", "))")
    if let d = service.description { print(d) }
    if let repo = service.repo { print("repository: \(repo)") }
    if !service.aliases.isEmpty { print("also known as: " + service.aliases.joined(separator: ", ")) }
    let status = (try? store.status(service: service)) ?? [:]
    print("\nkeys" + service.envs.map { "  " + $0 }.joined())
    for key in service.keys {
        let marks = service.envs.map { status[$0]?.contains(key.name) == true ? "  set" : "  —  " }
        print("  " + pad(key.name + (key.secret ? " *" : ""), 30) + marks.joined())
    }
    if !service.endpoints.isEmpty {
        print("\nendpoints")
        for e in service.endpoints {
            print("  " + pad(e.id, 12) + pad(e.label ?? "", 26) + (e.requires.isEmpty ? "" : "requires " + e.requires.joined(separator: ", ")))
        }
    }
    if !service.conditionIDs.isEmpty {
        print("\nconditions")
        for id in service.conditionIDs {
            let c = registry.condition(id)
            print("  " + pad(id, 18) + (c.map { $0.name + ($0.hint.map { " — \($0)" } ?? "") } ?? "not declared in any space"))
        }
    }
    if !service.guards.isEmpty { print("\nguards"); service.guards.forEach { print("  · " + $0) } }
    let out = registry.links(of: service.id), incoming = registry.links(to: service.id)
    if !out.isEmpty || !incoming.isEmpty { print("\nlinks") }
    for l in out { print("  → " + linkLine(l.to, l)) }
    for (from, l) in incoming { print("  ← " + linkLine(from, l, incoming: true)) }
    if let notes = registry.notes(of: service.id), !notes.isEmpty { print("\nnotes\n" + notes) }
    let docs = registry.docs(of: service.id)
    if !docs.isEmpty { print("docs"); docs.forEach { print("  [\($0.kind.rawValue)] \($0.title)" + ($0.section.map { " § \($0)" } ?? "")) } }
    let fields = registry.fields(of: service.id)
    if !fields.isEmpty { print("\nfields: \(fields.count), described \(fields.filter { $0.meaning != nil }.count)") }
    let practices = PracticeStore(registry: registry).list(service: service.id)
    if !practices.isEmpty { print("\npractices\n  " + practices.map(\.name).joined(separator: "  ")) }

case "links":
    let registry = Registry()
    if positional.count > 1 {
        guard registry.dir(of: positional[1]) != nil else { fail("no service \(positional[1])") }
        let out = registry.links(of: positional[1]), incoming = registry.links(to: positional[1])
        if json { printJSON(out.map { placed($0, from: positional[1]) } + incoming.map { placed($0.link, from: $0.from) }); break }
        for l in out { print("→ " + linkLine(l.to, l)) }
        for (from, l) in incoming { print("← " + linkLine(from, l, incoming: true)) }
        let refused = registry.rejected(of: positional[1])
        if out.isEmpty && incoming.isEmpty { print("no links") }
        if !refused.isEmpty { print("отклонено: " + refused.map { [$0.to, $0.via, $0.via == "topic" ? $0.what : nil].compactMap { $0 }.joined(separator: " ") }.joined(separator: ", ")) }
        break
    }
    let all = registry.serviceIDs().map { (from: $0, links: registry.links(of: $0)) }.filter { !$0.links.isEmpty }
    if json { printJSON(all.flatMap { from, links in links.map { placed($0, from: from) } }); break }
    for (from, links) in all { for l in links { print(pad(from, 24) + "→ " + linkLine(l.to, l)) } }

case "link":
    let (rest, options) = parse(args)
    guard rest.count == 4, ["add", "reject", "unreject"].contains(rest[1]) else { print(usage); exit(2) }
    var names = Link.Names()
    for pair in options["--as"] ?? [] {
        let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
        guard kv.count == 2 else { fail("--as is VAR=KEY", 2) }
        names[kv[0]] = kv[1]
    }
    let origin = options["--origin"]?.last ?? "manual"
    let link = Link(to: rest[3], endpoint: options["--endpoint"]?.last, env: options["--env"]?.last, via: options["--via"]?.last,
                    what: options["--what"]?.last, access: options["--access"]?.last, why: options["--why"]?.last,
                    practice: options["--practice"]?.last, names: names.isEmpty ? nil : names, file: options["--file"]?.last,
                    origin: origin)
    let registry = Registry()
    let (from, commit) = (rest[2], !args.contains("--no-commit"))
    do {
        var files: [URL] = []
        switch rest[1] {
        case "add": files = [try registry.addLink(link, from: from)]
        case "reject":
            guard let why = link.why else { fail("link reject needs --why: what in the code shows the link is false", 2) }
            files = try registry.reject(link, from: from, why: why, origin: origin)
        default:
            guard let file = try registry.unreject(link, from: from) else { fail("\(from) has no refused link to \(rest[3]) with that via/what") }
            files = [file]
        }
        let verb = rest[1] == "add" ? "" : rest[1] == "reject" ? "reject " : "unreject "
        if commit { try await registry.commit("\(verb)\(from) → \(rest[3])", files) }
    } catch { fail("practices: \(error)") }
    let tail = commit ? "" : "  (not committed — `practicesctl pending`, then `accept`)"
    switch rest[1] {
    case "add": print("\(from) → " + linkLine(rest[3], link) + tail)
    case "reject": print("\(from) ✕ " + linkLine(rest[3], Link(to: rest[3], via: link.via, what: link.what, why: link.why)) + tail)
    default: print("\(from) → \(rest[3]): no longer refused" + tail)
    }

case "conditions":
    let registry = Registry()
    let services = try registry.services()
    var rows: [(space: String, condition: Condition)] = []
    for space in registry.spaceIDs() where positional.count < 2 || positional[1] == space {
        rows += registry.conditions(space: space).map { (space, $0) }
    }
    if json { printJSON(rows.map(\.condition)); break }
    if rows.isEmpty { print("no conditions — `practicesctl condition add <space>/<id> --name N`"); break }
    for (space, c) in rows {
        print(pad(c.id, 20) + pad(space, 14) + pad(c.reachable == nil ? "declared" : "checked", 10) + c.name + (c.hint.map { " — \($0)" } ?? ""))
        let users = services.filter { $0.conditionIDs.contains(c.id) }.map(\.id)
        if !users.isEmpty { print(String(repeating: " ", count: 20) + "required by " + users.joined(separator: ", ")) }
    }

case "condition":
    let (rest, options) = parse(args)
    let parts = rest.count == 3 && rest[1] == "add" ? rest[2].split(separator: "/", maxSplits: 1).map(String.init) : []
    guard parts.count == 2, let name = options["--name"]?.last else { print(usage); exit(2) }
    do {
        try await Registry().add(Condition(id: parts[1], name: name, hint: options["--hint"]?.last,
                                           reachable: options["--reachable"]?.last), to: parts[0])
    } catch { fail("practices: \(error)") }
    print("condition \(parts[1]) in \(parts[0])")

case "scan":
    let registry = Registry()
    let result: ScanResult
    var written: [URL] = []
    do {
        result = try Scanner.scan(Array(positional.dropFirst()), registry: registry)
        if args.contains("--write") { written = try Scanner.write(result, registry: registry) }
    } catch { fail("practices: \(error)") }
    if json { printJSON(result); break }
    // One env file is often shared by many services: its links are printed once, under their callers.
    func show(_ found: [ScanResult.Found]) {
        var callers: [Link: [String]] = [:], heads: [String] = [], rows: [String: [String]] = [:]
        for f in found { callers[f.link, default: []].append(f.from) }
        for f in found where callers[f.link]?.first == f.from {
            let head = callers[f.link]!.joined(separator: ", ") + "  ← " + (f.link.origin ?? "").dropFirst(8)
            if rows[head] == nil { heads.append(head) }
            rows[head, default: []].append("→ " + linkLine(f.link.to, f.link)
                + (f.link.names.map { "  " + $0.map { "\($0)=\($1)" }.sorted().joined(separator: " ") } ?? ""))
        }
        for head in heads { print("    " + head); rows[head]!.forEach { print("      " + $0) } }
    }
    for repo in result.repos {
        print("\(repo.repo)  [\(repo.project)]  " + (repo.clone.map(home) ?? "not cloned"))
        if !repo.services.isEmpty { print("  new services") }
        for s in repo.services { print("    " + pad(s.id, 30) + "  " + pad(s.kind, 12) + (s.aliases.first.map { "compose: \($0)" } ?? "")) }
        if !repo.oneOff.isEmpty { print("  run once, not services: " + repo.oneOff.joined(separator: ", ")) }
        if !repo.new.isEmpty { print("  new links") }
        show(repo.new)
        if !repo.present.isEmpty { print("  in the catalogue already: \(repo.present.count) links") }
        if !repo.rejected.isEmpty { print("  \(repo.rejected.count) отклонены ранее" + (args.contains("--all") ? "" : " (--all: list)")) }
        if args.contains("--all") { show(repo.rejected) }
        if !repo.gone.isEmpty { print("  gone (derived before, not found now; nothing is deleted)") }
        for f in repo.gone { print("    " + [f.from, "→", f.link.to, f.link.via, f.link.what].compactMap { $0 }.joined(separator: " ")) }
        if !repo.unknown.isEmpty { print("  unknown") }
        for u in repo.unknown {
            let what = u.build.map { "build context in \($0): which service?" } ?? u.topic.map { "topic \($0): no link to a broker" }
                ?? (u.host ?? "") + (u.port.map { ":\($0)" } ?? "")
            print("    " + pad(u.variable ?? "build", 32) + "  " + pad(what, 40) + "  " + pad(u.file, 28) + "  " + u.callers.joined(separator: ", "))
        }
        repo.problems.forEach { print("  ! " + $0) }
    }
    if !result.networks.isEmpty { print("shared networks") }
    for (name, repos) in result.networks.sorted(by: { $0.key < $1.key }) { print("  " + pad(name, 20) + "  " + repos.joined(separator: ", ")) }
    if !written.isEmpty { print("\nwritten, not committed: \(written.count) files — `practicesctl pending`, then `accept`") }

case "pending":
    let pending = await Registry().pending()
    if json { printJSON(pending); break }
    if pending.isEmpty { print("nothing pending"); break }
    for p in pending { print(pad(p.state, 10) + pad(p.space, 14) + p.path) }
    print("\n`practicesctl accept [space [path…]]` commits them; `git -C <space> diff` shows them")

case "accept":
    let (rest, options) = parse(args)
    do {
        let accepted = try await Registry().accept(space: rest.count > 1 ? rest[1] : nil, paths: Array(rest.dropFirst(2)),
                                                   message: options["--message"]?.last)
        if accepted.isEmpty { print("nothing pending"); break }
        for p in accepted { print("accepted  " + pad(p.space, 14) + p.path) }
    } catch { fail("practices: \(error)") }

case "discard":
    guard positional.count >= 3 else { print(usage); exit(2) }
    let registry = Registry()
    let chosen = await registry.pending().filter { $0.space == positional[1] && positional.dropFirst(2).contains($0.path) }
    if chosen.isEmpty { print("nothing pending at those paths"); break }
    for p in chosen {
        do { try await registry.discard(p) } catch { fail("practices: \(error)") }
        print("discarded " + pad(p.space, 14) + p.path)
    }

case "check":
    let registry = Registry(), store = SecretStore()
    var targets: [(Service, String)] = []
    let refs = positional.dropFirst().map(ServiceRef.init(parsing:))
    let all = try registry.services()
    for service in all where refs.isEmpty || refs.contains(where: { $0.service == service.id }) {
        let wanted = refs.first { $0.service == service.id }?.env
        for env in service.envs where wanted == nil || wanted == env { targets.append((service, env)) }
    }
    var results: [CheckResult] = []
    await withTaskGroup(of: [CheckResult].self) { group in
        for (service, env) in targets {
            group.addTask {
                let values = (try? store.values(service: service.id, env: env)) ?? [:]
                return await Checks.conditions(service, env: env, values: values, registry: registry)
                    + Checks.check(service, env: env, values: values)
            }
        }
        for await r in group { results += r }
    }
    results.sort { ($0.service, $0.env) < ($1.service, $1.env) }
    if json { printJSON(results); break }
    for r in results {
        let mark = r.ok ? "●" : "✗"
        print("\(mark) " + pad("\(r.service)@\(r.env)", 24) + pad(r.endpoint, 26)
              + pad(r.millis.map { "\($0) ms" } ?? "", 9) + (r.message ?? ""))
    }

case "secrets":
    let store = SecretStore(), registry = Registry()
    if positional.count >= 3, positional[1] == "import" {
        let ref = ServiceRef(parsing: positional[2])
        guard var service = try? registry.service(ref.service), let env = ref.env else { print("give <service>@<env>"); exit(2) }
        var dotenv: [String: String] = [:]
        if let i = args.firstIndex(of: "--from"), i + 1 < args.count {
            let text = try String(contentsOfFile: args[i + 1], encoding: .utf8)
            for (k, v) in EnvFiles.parseDotenv(text) { dotenv[k] = v }
        }
        let fromPath = args.firstIndex(of: "--from").map { args[$0 + 1] }
        var values: [String: String] = [:]
        var problems: [String] = []
        for spec in positional.dropFirst(3) where spec != fromPath {
            if let r = spec.range(of: ":=") {
                values[String(spec[..<r.lowerBound])] = String(spec[r.upperBound...])
            } else if let eq = spec.firstIndex(of: "=") {
                let key = String(spec[..<eq]), from = String(spec[spec.index(after: eq)...])
                if from.hasPrefix("env:") {
                    let other = String(from.dropFirst(4))
                    if let v = try store.values(service: service.id, env: other)[key] { values[key] = v } else { problems.append("\(key): no value in \(other)") }
                } else if let v = dotenv[from], !v.isEmpty {
                    values[key] = v
                } else {
                    problems.append("\(key): \(from) not in the file")
                }
            }
        }
        if !service.envs.contains(env) {
            service.envs.append(env)
            try await registry.commit("\(service.id): environment \(env)", [try registry.save(service)])
        }
        try store.setAll(values, service: service.id, env: env)
        let status = try store.status(service: service)[env] ?? []
        print("\(service.id)@\(env): \(values.count) values stored, \(status.count)/\(service.keys.count) keys set")
        let missing = service.keys.map(\.name).filter { !status.contains($0) }
        if !missing.isEmpty { print("not set: " + missing.joined(separator: ", ")) }
        problems.forEach { print("skipped " + $0) }
        break
    }
    guard positional.count >= 4, ["set", "unset"].contains(positional[1]) else { print(usage); exit(2) }
    let id = positional[2], key = positional[3]
    guard let service = try? registry.service(id) else { print("no service \(id)"); exit(1) }
    let env = args.firstIndex(of: "--env").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? service.defaultEnv
    guard service.envs.contains(env) else { print("\(id) has environments " + service.envs.joined(separator: ", ")); exit(1) }
    if positional[1] == "unset" {
        try store.remove(key: key, service: id, env: env)
        print("\(id)@\(env) \(key): unset")
        break
    }
    // From stdin, so the value stays out of shell history and `ps`.
    var value: String?
    if isatty(0) != 0 {
        var buffer = [CChar](repeating: 0, count: 4096)
        value = readpassphrase("\(key) for \(id)@\(env): ", &buffer, buffer.count, 0).map { String(cString: $0) }
    } else {
        value = readLine(strippingNewline: true)
    }
    guard let value, !value.isEmpty else { print("empty value, nothing stored"); exit(1) }
    try store.set(value, key: key, service: id, env: env)
    if !service.keys.contains(where: { $0.name == key }) {
        var updated = service
        updated.keys.append(Service.Key(name: key))
        try await registry.commit("\(id): declare \(key)", [try registry.save(updated)])
    }
    print("\(id)@\(env) \(key): set")

case "env", "run":
    let separator = args.firstIndex(of: "--")
    let before = separator.map { Array(args[..<$0]) } ?? args
    let refs = before.dropFirst().filter { !$0.hasPrefix("--") }.map(ServiceRef.init(parsing:))
    guard !refs.isEmpty else { print("which services? usage: practicesctl \(positional[0]) <ref…>" + (positional[0] == "run" ? " -- <command…>" : "")); exit(2) }
    let registry = Registry(), store = SecretStore()
    let resolved: RunEnvironment.Resolved
    do { resolved = try RunEnvironment.resolve(refs, registry: registry, store: store) } catch { print("practices: \(error)"); exit(1) }
    for (ref, keys) in resolved.missing.sorted(by: { $0.key < $1.key }) {
        FileHandle.standardError.write(Data("practices: \(ref) has no value for \(keys.joined(separator: ", "))\n".utf8))
    }
    if positional.first == "env" {
        for key in resolved.values.keys.sorted() { print(key) }
        break
    }
    guard let separator, separator + 1 < args.count else { print("usage: practicesctl run <ref…> -- <command…>"); exit(2) }
    // Conditions first: a sentence now instead of a timeout later.
    var unmet: [String] = []
    for (service, env) in resolved.services {
        let values = (try? store.values(service: service.id, env: env)) ?? [:]
        unmet += await Checks.unmet(service, env: env, values: values, registry: registry)
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

case "connect":
    guard let toIndex = args.firstIndex(of: "--to"), toIndex + 1 < args.count else { print(usage); exit(2) }
    let project = URL(fileURLWithPath: args.firstIndex(of: "--project").map { args[$0 + 1] } ?? FileManager.default.currentDirectoryPath).standardizedFileURL
    var refs: [ServiceRef] = [], aliases: [String: String] = [:], only: [String]?
    var i = 1
    let rest = Array(CommandLine.arguments.dropFirst())
    while i < rest.count {
        let a = rest[i]
        if ["--to", "--project"].contains(a) { i += 2; continue }
        if a == "--as", i + 1 < rest.count {
            let kv = rest[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { aliases[kv[0]] = kv[1] }
            i += 2; continue
        }
        if a == "--only", i + 1 < rest.count { only = rest[i + 1].split(separator: ",").map(String.init); i += 2; continue }
        if a.hasPrefix("--") { i += 1; continue }
        refs.append(ServiceRef(parsing: a)); i += 1
    }
    guard !refs.isEmpty else { print("which services? e.g. clickhouse@dev"); exit(2) }
    // Stateless: the file is written now and nothing remembers it (DECISIONS 18).
    let file = ManagedFile(path: args[toIndex + 1], services: refs, env: aliases, only: only)
    do {
        let lines = try await EnvFiles.write(file, project: project, force: args.contains("--force"))
        print("\(home(project.appendingPathComponent(file.path).path)): " + summary(lines))
        for l in lines where l.state != .same {
            print("  " + pad(l.variable, 32) + pad(l.variable == l.key ? "" : "← \(l.key)", 28) + pad("\(l.service)@\(l.env)", 18) + l.state.rawValue)
        }
    } catch { print("practices: \(error)"); exit(1) }

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
    let list = positional.count > 1 ? store.list(service: positional[1]) : store.all()
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
        print("\nfailed: \(result.error ?? "")")
        if result.conditions != nil { print("declared conditions of its services (not checked):") }
        for c in result.conditions ?? [] { print("  " + pad(c.id, 18) + c.name + (c.hint.map { " — \($0)" } ?? "")) }
        print((result.traceback ?? "") + (result.stderr.isEmpty ? "" : "\n-- stderr\n" + result.stderr))
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
        var line = "  " + pad("\(hit.service) · \(hit.field.path)", 40) + pad(hit.field.type ?? "", 8)
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
    for hit in results.docs { print("  " + pad((hit.service ?? "") + " · " + hit.title, 34) + hit.excerpt) }
    if !results.code.isEmpty { print("\nCODE") }
    for hit in results.code { print("  " + pad(hit.title, 34) + hit.excerpt) }
    let (projectHits, files) = await ProjectCode.search(positional.dropFirst().joined(separator: " "))
    if !projectHits.isEmpty { print("\nIN PROJECT CODE (\(files) files, not practices yet)") }
    for hit in projectHits.prefix(12) {
        print("  " + pad(hit.function.map { "\($0)()" } ?? "", 30) + home(hit.path) + ":\(hit.line)")
    }
    if projectHits.count > 12 { print("  … \(projectHits.count - 12) more") }

case "mcp":
    MCPServer().serve()

case "copies":
    let copies = await Copies.scan().filter { c in positional.count < 2 || c.ref == positional[1] }
    if json { printJSON(copies); break }
    if copies.isEmpty { print("no marked copies in ~/Projects"); break }
    for c in copies {
        print(pad(c.state.rawValue, 10) + pad(c.ref + (c.version.map { "@v\($0)" } ?? ""), 36)
              + pad("latest v\(c.latest)", 11) + home(c.path) + ":\(c.line)")
    }

default:
    print(usage)
    exit(positional.isEmpty ? 0 : 2)
}
