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
