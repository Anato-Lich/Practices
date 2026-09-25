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
    var lastError: String?

    var popoverVisible = false {
        didSet { if popoverVisible && !oldValue { Task { await refresh() } } }
    }

    private var expectStop: AsyncStream<String>.Continuation?
    private var started = false

    /// What the menu-bar badge counts: things that went wrong while we were watching plus
    /// containers that are unhealthy or restarting right now. Old exits are listed in the
    /// popover but do not light the badge.
    var alertCount: Int {
        let live = (snapshot?.containers ?? []).filter {
            $0.isUnhealthy || $0.state == "restarting" || $0.state == "dead"
        }
        let ids = Set(live.map(\.id)).union(incidents.map(\.containerID))
        return ids.count
    }

    func start() {
        guard !started, !CommandLine.arguments.contains("--render-popover") else { return }
        started = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let (stream, continuation) = AsyncStream<String>.makeStream()
        expectStop = continuation
        Task {
            for await incident in DockerEvents.incidents(expectStop: stream) {
                incidents.insert(incident, at: 0)
                if incidents.count > 50 { incidents.removeLast() }
                notify(incident)
                await refresh()
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
