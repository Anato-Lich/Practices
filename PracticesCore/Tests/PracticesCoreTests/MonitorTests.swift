import Testing
import Foundation
@testable import PracticesCore

@Suite struct ListeningPortsTests {
    @Test func collapsesAddressFamilies() {
        let output = """
            p621
            cControlCenter
            f9
            n*:7000
            f10
            n*:7000
            p1202
            cCode Helper (Plugin)
            f53
            n127.0.0.1:21299
            p900
            cpython3
            f3
            n127.0.0.1:8000
            f4
            n[::]:8000
            """
        let sockets = ListeningPorts.parse(lsofFields: output)
        #expect(sockets.map(\.port) == [7000, 8000, 21299])
        #expect(sockets[1].address == "*")
        #expect(sockets[2].command == "Code Helper (Plugin)")
        #expect(sockets[2].isLoopbackOnly)
    }
}

@Suite struct DockerParsingTests {
    @Test func portsColumn() {
        let ports = Docker.parse(ports: "0.0.0.0:58123->8123/tcp, [::]:58123->8123/tcp, 48210/tcp, 127.0.0.1:9000-9001->9000-9001/tcp")
        #expect(ports.map(\.hostPort) == [58123, 9000, 9001])
        #expect(ports[0].containerPort == 8123)
        #expect(ports[2].containerPort == 9001)
        #expect(ports[1].hostAddress == "127.0.0.1")
    }

    @Test func psLines() {
        let line = #"{"id":"ad28","name":"api-1","image":"x","state":"exited","status":"Exited (137) 3 minutes ago","ports":"","project":"billing","service":"api","workdir":"/Users/u/Projects/billing"}"#
        let containers = Docker.parse(psOutput: line + "\nnot json\n")
        #expect(containers.count == 1)
        #expect(containers[0].exitCode == 137)
        #expect(containers[0].orbDomain == "api.billing.orb.local")
        #expect(Docker.parse(psOutput: line.replacingOccurrences(of: #""project":"billing""#, with: #""project":"""#))[0].composeProject == nil)
    }
}

@Suite struct IncidentDetectorTests {
    func die(_ id: String, code: Int, at t: Int) -> DockerEvent {
        DockerEvent(Type: "container", Action: "die",
                    Actor: .init(ID: id, Attributes: ["name": "api-1", "exitCode": String(code)]), time: t)
    }

    @Test func quietStopsAreNotCrashes() {
        var d = IncidentDetector()
        #expect(d.consume(die("a", code: 0, at: 0)).isEmpty)
        #expect(d.consume(die("b", code: 143, at: 0)).isEmpty)
        #expect(d.consume(die("c", code: 1, at: 0)).map(\.kind) == [.crashed])
    }

    @Test func restartLoopReportedOnce() {
        var d = IncidentDetector()
        let kinds = (0..<6).flatMap { d.consume(die("a", code: 1, at: $0 * 10)) }.map(\.kind)
        #expect(kinds == [.crashed, .restartLoop])
    }

    @Test func expectedStopIsSilent() {
        var d = IncidentDetector()
        d.expectStop(of: "a", at: Date(timeIntervalSince1970: 100))
        #expect(d.consume(die("a", code: 137, at: 105)).isEmpty)
        #expect(d.consume(die("a", code: 137, at: 500)).map(\.kind) == [.crashed])
    }
}

@Suite struct MergeTests {
    @Test func containerPortsReplaceForwarderSockets() {
        let container = Container(
            id: "1", name: "db-1", image: "postgres", state: "running", status: "Up",
            ports: [PublishedPort(hostAddress: "0.0.0.0", hostPort: 5432, containerPort: 5432, proto: "tcp")],
            composeProject: "analytics", composeService: "db", workingDir: nil)
        let sockets = [
            ListeningSocket(port: 5432, address: "*", pid: 10, command: "com.docker.backend"),
            ListeningSocket(port: 5173, address: "127.0.0.1", pid: 20, command: "node"),
        ]
        let entries = Monitor.merge(sockets: sockets, containers: [container],
                                    cwds: [20: "/Users/u/Projects/dashboard/web"], root: "/Users/u/Projects")
        #expect(entries.map(\.port) == [5173, 5432])
        #expect(entries[0].project == "dashboard")
        #expect(entries[1].project == "analytics")
    }
}

@Suite struct ComposeTests {
    @Test func fileClassification() {
        #expect(ComposeScanner.isComposeFile("docker-compose.dev.yml"))
        #expect(ComposeScanner.isComposeFile("compose.yaml"))
        #expect(!ComposeScanner.isComposeFile("docker-compose.md"))
        #expect(ComposeScanner.isServerFile("docker-compose.prod.yml"))
        #expect(ComposeScanner.isServerFile("docker-compose.stage.yml"))
        #expect(!ComposeScanner.isServerFile("docker-compose.dev.yml"))
        #expect(ComposeScanner.isOverlay("docker-compose.ports.yml"))
        #expect(ComposeScanner.bases(for: "/p/a/docker-compose.ports.yml",
                                     among: ["/p/a/docker-compose.yml", "/p/a/docker-compose.dev.yml", "/p/a/docker-compose.ports.yml"])
                == ["/p/a/docker-compose.dev.yml", "/p/a/docker-compose.yml"])
    }

    @Test func configPorts() throws {
        let json = #"{"name":"imu-sphere","services":{"frontend":{"ports":[{"target":5173,"published":"5173","protocol":"tcp"}]},"worker":{},"range":{"ports":[{"target":9000,"published":"9000-9001"},{"target":53,"published":"53","protocol":"udp"}]}}}"#
        let claims = try ComposeScanner.parse(configJSON: Data(json.utf8), files: ["f"])
        #expect(Set(claims.map(\.hostPort)) == [5173, 9000, 9001])
        let frontend = claims.first { $0.service == "frontend" }!
        #expect(frontend.orbURL == "http://frontend.imu-sphere.orb.local:5173")
    }

    @Test func conflictIgnoresOwnContainer() {
        let own = Container(id: "1", name: "db-1", image: "pg", state: "running", status: "Up",
                            ports: [PublishedPort(hostAddress: "0.0.0.0", hostPort: 5433, containerPort: 5432, proto: "tcp")],
                            composeProject: "imu", composeService: "postgres", workingDir: nil)
        let frontend = Container(id: "2", name: "fe-1", image: "node", state: "running", status: "Up",
                                 ports: [PublishedPort(hostAddress: "0.0.0.0", hostPort: 5175, containerPort: 5173, proto: "tcp")],
                                 composeProject: "imu", composeService: "frontend", workingDir: nil)
        let snapshot = MonitorSnapshot(
            date: Date(), dockerContext: "orbstack", containers: [own, frontend], dockerError: nil,
            ports: Monitor.merge(sockets: [ListeningSocket(port: 5173, address: "[::1]", pid: 7, command: "node")],
                                 containers: [own, frontend], cwds: [7: "/u/Projects/SphereTele"], root: "/u/Projects"))
        let claims = [
            PortClaim(project: "imu", service: "postgres", hostPort: 5433, containerPort: 5432, hostIP: nil, files: []),
            PortClaim(project: "imu", service: "frontend", hostPort: 5173, containerPort: 5173, hostIP: nil, files: []),
        ]
        let conflicts = PortConflicts.conflicts(claims: claims, snapshot: snapshot)
        #expect(conflicts.count == 1)
        #expect(conflicts[0].claim.service == "frontend")
        #expect(conflicts[0].holders.first?.project == "SphereTele")
        #expect(conflicts[0].runningOn == [5175])
    }
}

@Suite struct IncidentRulesTests {
    func event(_ action: String, _ id: String, name: String, code: Int? = nil, at t: Int, labels: [String: String] = [:]) -> DockerEvent {
        var attrs = labels
        attrs["name"] = name
        if let code { attrs["exitCode"] = String(code) }
        return DockerEvent(Type: "container", Action: action, Actor: .init(ID: id, Attributes: attrs), time: t)
    }
    let service = ["com.docker.compose.project": "route-verdict", "com.docker.compose.service": "route-verdict",
                   "com.docker.compose.container-number": "1"]
    let fromImage = ["com.docker.compose.project": "route-verdict", "com.docker.compose.service": "route-verdict"]

    @Test func killBeforeDieIsAStop() {
        var d = IncidentDetector()
        #expect(d.consume(event("kill", "a", name: "route-verdict", at: 0, labels: service)).isEmpty)
        #expect(d.consume(event("die", "a", name: "route-verdict", code: 137, at: 10, labels: service)).isEmpty)
        // 137 with nobody asking: killed from inside or by memory pressure — worth knowing.
        #expect(d.consume(event("die", "b", name: "worker", code: 137, at: 20, labels: service)).map(\.kind) == [.crashed])
    }

    @Test func throwawayContainersAreQuiet() {
        var d = IncidentDetector()
        #expect(d.consume(event("health_status: unhealthy", "t", name: "epic_chatelet", at: 0, labels: fromImage)).isEmpty)
        #expect(d.consume(event("die", "t", name: "cranky_shirley", code: 1, at: 1, labels: fromImage)).isEmpty)
        #expect(d.consume(event("die", "o", name: "rv-run-1", code: 1, at: 2, labels: service.merging(["com.docker.compose.oneoff": "True"]) { $1 })).isEmpty)
        // A named `docker run` is somebody's service: still watched.
        #expect(d.consume(event("die", "n", name: "rv-scope-tmp", code: 1, at: 3, labels: fromImage)).map(\.kind) == [.crashed])
    }

    @Test func unhealthyOnceUntilHealthy() {
        var d = IncidentDetector()
        #expect(d.consume(event("health_status: unhealthy", "a", name: "route-verdict", at: 0, labels: service)).count == 1)
        #expect(d.consume(event("health_status: unhealthy", "a", name: "route-verdict", at: 30, labels: service)).isEmpty)
        #expect(d.consume(event("health_status: healthy", "a", name: "route-verdict", at: 60, labels: service)).isEmpty)
        #expect(d.consume(event("health_status: unhealthy", "a", name: "route-verdict", at: 90, labels: service)).count == 1)
    }

    @Test func oomIsReportedOnce() {
        var d = IncidentDetector()
        #expect(d.consume(event("oom", "a", name: "api", at: 0, labels: service)).map(\.kind) == [.outOfMemory])
        #expect(d.consume(event("die", "a", name: "api", code: 137, at: 1, labels: service)).isEmpty)
    }
}
