import Foundation
import PracticesCore

// practicesctl — the core without the app. Every monitor feature is reachable from here
// first (DECISIONS 6), so it can be checked in a terminal before any UI exists for it.

let usage = """
    usage: practicesctl <command> [--json]

      ports         occupied TCP ports and who holds them
      containers    containers, failed ones first
      watch         print container incidents as they happen (Ctrl-C to stop)
      logs <name>   last 200 log lines of a container
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

default:
    print(usage)
    exit(positional.isEmpty ? 0 : 2)
}
