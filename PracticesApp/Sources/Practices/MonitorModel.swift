import Foundation
import AppKit
import Observation
import UserNotifications
import PracticesCore

/// State behind the menu-bar item: the latest snapshot, incidents since launch, and the
/// actions the popover offers. Refreshes fast only while someone is looking (DECISIONS 8).
@MainActor @Observable
final class MonitorModel {

    private(set) var snapshot: MonitorSnapshot?
    /// Incidents from the event stream, newest first. Cleared by the user, not by time.
    private(set) var incidents: [ContainerIncident] = []
    private(set) var busy: Set<String> = []
    private(set) var composeScan: ComposeScan?

    /// Ports compose files want that something else holds, against the latest snapshot.
    var conflicts: [PortConflict] {
        guard let scan = composeScan, let snapshot else { return [] }
        return PortConflicts.conflicts(claims: scan.claims, snapshot: snapshot)
    }
    var lastError: String?

    var popoverVisible = false {
        didSet {
            guard popoverVisible && !oldValue else { return }
            Task { await refresh() }
        }
    }

    private var expectStop: AsyncStream<String>.Continuation?
    private var started = false

    /// What the menu-bar badge counts: things that went wrong while we were watching plus
    /// containers that are unhealthy or restarting right now. Old exits are listed in the
    /// popover but do not light the badge.
    var alertCount: Int {
        let live = (snapshot?.containers ?? []).filter {
            !$0.isEphemeral && ($0.isUnhealthy || $0.state == "restarting" || $0.state == "dead")
        }
        let ids = Set(live.map(\.id)).union(incidents.map(\.containerID))
        return ids.count
    }

    func start() {
        guard !started, !CommandLine.arguments.contains("--render-popover"), !CommandLine.arguments.contains("--check-to") else { return }
        started = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let (stream, continuation) = AsyncStream<String>.makeStream()
        expectStop = continuation
        Task {
            for await incident in DockerEvents.incidents(expectStop: stream) {
                Self.log(incident)
                incidents.insert(incident, at: 0)
                if incidents.count > 50 { incidents.removeLast() }
                notify(incident)
                await refresh()
            }
        }
        Task {
            // Compose files change rarely; a full pass is ~2 s of short docker processes.
            while !Task.isCancelled {
                await rescanCompose()
                try? await Task.sleep(for: .seconds(300))
            }
        }
        Task {
            var last = Date.distantPast
            while !Task.isCancelled {
                let interval: TimeInterval = popoverVisible ? 3 : 60
                if Date().timeIntervalSince(last) >= interval {
                    await refresh()
                    last = Date()
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func refresh() async {
        snapshot = await Monitor.snapshot()
        expireRecovered()
    }

    /// How long a container must run again (and not be unhealthy) before its incident clears
    /// by itself: the badge is for what needs attention, not a history of everything.
    static let recoveryWindow: TimeInterval = 600

    private func expireRecovered() {
        guard let containers = snapshot?.containers else { return }
        let now = Date()
        incidents.removeAll { incident in
            guard now.timeIntervalSince(incident.date) > Self.recoveryWindow,
                  let c = containers.first(where: { $0.id == incident.containerID || $0.name == incident.name }) else { return false }
            return c.isRunning && !c.isUnhealthy && c.state != "restarting"
        }
    }

    /// Every incident also goes to ~/.practices/incidents.jsonl, so one can be looked up after
    /// the fact (Docker keeps only a short event history).
    static func log(_ incident: ContainerIncident) {
        let url = PracticesHome.url.appendingPathComponent("incidents.jsonl")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(incident) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? line.write(to: url)
        }
    }

    func rescanCompose() async {
        composeScan = await ComposeScanner.scan()
    }

    func openURL(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    func openAirPlaySettings() {
        openURL("x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension")
    }

    func clearIncidents() { incidents.removeAll() }

    func dismiss(_ incident: ContainerIncident) {
        incidents.removeAll { $0.containerID == incident.containerID }
    }

    // MARK: Actions

    func stop(_ container: Container) { containerAction(container, expectExit: true) { try await Docker.stop($0) } }
    func kill(_ container: Container) { containerAction(container, expectExit: true) { try await Docker.kill($0) } }
    func start(_ container: Container) { containerAction(container, expectExit: false) { try await Docker.start($0) } }

    func terminate(pid: Int32) {
        let key = "pid-\(pid)"
        busy.insert(key)
        Task {
            if !(await Monitor.terminate(pid: pid)) { lastError = String(localized: "Could not stop process \(pid)") }
            busy.remove(key)
            await refresh()
        }
    }

    private func containerAction(_ container: Container, expectExit: Bool,
                                 _ action: @escaping @Sendable (String) async throws -> Void) {
        busy.insert(container.id)
        if expectExit { expectStop?.yield(container.id) }
        Task {
            do { try await action(container.id) } catch { lastError = String(describing: error) }
            incidents.removeAll { $0.containerID == container.id }
            busy.remove(container.id)
            await refresh()
        }
    }

    func openInBrowser(port: Int) {
        if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Notifications

    private func notify(_ incident: ContainerIncident) {
        let content = UNMutableNotificationContent()
        content.title = incident.name
        content.subtitle = incident.composeProject ?? ""
        content.body = Self.describe(incident)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "\(incident.containerID)-\(incident.kind.rawValue)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func describe(_ incident: ContainerIncident) -> String {
        switch incident.kind {
        case .crashed:
            if let code = incident.exitCode { return String(localized: "Crashed with exit code \(code)") }
            return String(localized: "Crashed")
        case .outOfMemory: return String(localized: "Killed: out of memory")
        case .unhealthy: return String(localized: "Health check failing")
        case .restartLoop: return String(localized: "Restarting over and over")
        }
    }
}
