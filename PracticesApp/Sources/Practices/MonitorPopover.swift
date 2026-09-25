import SwiftUI
import AppKit
import ServiceManagement
import PracticesCore

struct MonitorPopover: View {
    @Environment(MonitorModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let snapshot = model.snapshot {
                        if snapshot.containers == nil { dockerDown(snapshot) }
                        attention(snapshot)
                        conflicts
                        ports(snapshot)
                        containers(snapshot)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(24)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 620)
            Divider()
            footer
        }
        .frame(width: 440)
        .onAppear { model.popoverVisible = true }
        .onDisappear { model.popoverVisible = false }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 8) {
            Text("Practices").font(.headline)
            if let context = model.snapshot?.dockerContext {
                Text(verbatim: context)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .help("Docker context")
            }
            Spacer()
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh")
            Button {
                NSApp.activate()
                openWindow(id: MainWindow.id)
            } label: { Image(systemName: "macwindow") }
                .buttonStyle(.borderless)
                .help("Open Practices")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            if let error = model.lastError {
                Text(verbatim: error).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .onTapGesture { model.lastError = nil }
            }
            Spacer()
            LaunchAtLoginToggle()
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func dockerDown(_ snapshot: MonitorSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Docker is not answering", systemImage: "exclamationmark.triangle")
                .font(.callout.weight(.semibold))
            if let error = snapshot.dockerError {
                Text(verbatim: error).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Attention

    @ViewBuilder
    private func attention(_ snapshot: MonitorSnapshot) -> some View {
        let byID = Dictionary((snapshot.containers ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let incidentIDs = Set(model.incidents.map(\.containerID))
        let live = (snapshot.containers ?? []).filter {
            ($0.isUnhealthy || $0.state == "restarting" || $0.state == "dead") && !incidentIDs.contains($0.id)
        }
        if !model.incidents.isEmpty || !live.isEmpty {
            Section {
                ForEach(uniqueIncidents, id: \.containerID) { incident in
                    AttentionRow(
                        title: incident.name,
                        detail: MonitorModel.describe(incident),
                        date: incident.date,
                        container: byID[incident.containerID],
                        onDismiss: { model.dismiss(incident) })
                }
                ForEach(live) { c in
                    AttentionRow(title: c.name, detail: c.status, date: nil, container: c, onDismiss: nil)
                }
            } header: {
                SectionHeader(title: "Attention") {
                    if !model.incidents.isEmpty {
                        Button("Clear") { model.clearIncidents() }.buttonStyle(.borderless).font(.caption)
                    }
                }
            }
        }
    }

    /// Latest incident per container.
    private var uniqueIncidents: [ContainerIncident] {
        var seen = Set<String>()
        return model.incidents.filter { seen.insert($0.containerID).inserted }
    }

    // MARK: Conflicts

    @ViewBuilder
    private var conflicts: some View {
        let conflicts = model.conflicts
        if !conflicts.isEmpty {
            Section {
                VStack(spacing: 6) {
                    ForEach(conflicts) { ConflictRow(conflict: $0) }
                }
            } header: {
                SectionHeader(title: "Port conflicts") {
                    Text(verbatim: String(conflicts.count)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Ports

    @ViewBuilder
    private func ports(_ snapshot: MonitorSnapshot) -> some View {
        let contested = snapshot.contestedPorts
        let visible = snapshot.ports.filter { $0.project != nil || contested.contains($0.port) || isDevPort($0) }
        Section {
            if visible.isEmpty {
                Text("No project is listening on a port").font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                ForEach(visible) { entry in
                    PortRow(entry: entry, contested: contested.contains(entry.port))
                }
            }
        } header: {
            SectionHeader(title: "Ports") { EmptyView() }
        }
    }

    /// Listeners outside ~/Projects that still look like development servers.
    private func isDevPort(_ entry: PortEntry) -> Bool {
        guard case .process(_, let command) = entry.owner else { return true }
        let dev = ["node", "python", "python3", "Python", "uvicorn", "ruby", "java", "go", "deno", "bun",
                   "postgres", "redis-server", "mongod", "clickhouse", "nginx", "php"]
        return dev.contains { command.hasPrefix($0) }
    }

    // MARK: Containers

    @ViewBuilder
    private func containers(_ snapshot: MonitorSnapshot) -> some View {
        if let containers = snapshot.containers, !containers.isEmpty {
            let groups = Dictionary(grouping: containers) { $0.composeProject ?? "—" }
            Section {
                ForEach(groups.keys.sorted(), id: \.self) { project in
                    ProjectGroup(project: project, containers: groups[project]!.sorted { $0.name < $1.name })
                }
            } header: {
                SectionHeader(title: "Containers") {
                    let running = containers.filter(\.isRunning).count
                    Text(verbatim: "\(running)/\(containers.count)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Rows

struct SectionHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Spacer()
            trailing()
        }
    }
}

struct AttentionRow: View {
    @Environment(MonitorModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let title: String
    let detail: String
    let date: Date?
    let container: Container?
    let onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title).font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(verbatim: detail)
                    if let date { Text(date, style: .relative) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let container {
                Button("Logs") { openLogs(container.id) }.buttonStyle(.borderless).font(.caption)
                if !container.isRunning {
                    Button("Start") { model.start(container) }.buttonStyle(.borderless).font(.caption)
                }
            }
            if let onDismiss {
                Button { onDismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Dismiss")
            }
        }
    }

    private func openLogs(_ id: String) {
        NSApp.activate()
        openWindow(id: LogsView.windowID, value: id)
    }
}

struct PortRow: View {
    @Environment(MonitorModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let entry: PortEntry
    let contested: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: String(entry.port))
                .font(.callout.monospacedDigit().weight(.medium))
                .frame(width: 48, alignment: .leading)
            Text(verbatim: entry.shortName).font(.callout).lineLimit(1).truncationMode(.middle)
            if contested {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help("More than one owner on this port")
            }
            Spacer(minLength: 8)
            if let project = entry.project {
                Text(verbatim: project).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Image(systemName: "lock").font(.caption).foregroundStyle(.tertiary)
                .opacity(entry.isLoopbackOnly ? 1 : 0)
                .help(entry.isLoopbackOnly ? "Loopback only" : "")
            HStack(spacing: 6) {
                Button { model.openInBrowser(port: entry.port) } label: { Image(systemName: "safari") }
                    .help("Open in browser")
                menu
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0.35)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var menu: some View {
        Menu {
            switch entry.owner {
            case .container(let c):
                Button("Logs") { NSApp.activate(); openWindow(id: LogsView.windowID, value: c.id) }
                Button("Copy \(c.orbDomain)") { model.copy(c.orbDomain) }
                Divider()
                Button("Stop container") { model.stop(c) }
                Button("Kill container") { model.kill(c) }
            case .process(let pid, _):
                Button("Copy PID \(String(pid))") { model.copy(String(pid)) }
                Divider()
                Button("Stop process") { model.terminate(pid: pid) }
            }
            if let dir = entry.projectDir {
                Divider()
                Button("Show project in Finder") { model.reveal(dir) }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

extension PortEntry {
    /// Compose service rather than the full `project-service-1` container name.
    var shortName: String {
        if case .container(let c) = owner { return c.composeService ?? c.name }
        return ownerName
    }

    var isLoopbackOnly: Bool {
        address == "127.0.0.1" || address == "[::1]" || address == "localhost"
    }
}

struct ProjectGroup: View {
    let project: String
    let containers: [Container]
    @State private var expanded = false

    var body: some View {
        let running = containers.filter(\.isRunning).count
        DisclosureGroup(isExpanded: $expanded) {
            VStack(spacing: 4) {
                ForEach(containers) { ContainerRow(container: $0) }
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Circle().fill(dotColor(running: running)).frame(width: 7, height: 7)
                Text(verbatim: project).font(.callout.weight(.medium))
                Spacer()
                Text(verbatim: "\(running)/\(containers.count)").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
        }
    }

    /// Red for anything failing now, orange for a container that last exited with an error,
    /// green when something runs, grey when the project is simply stopped.
    private func dotColor(running: Int) -> Color {
        if containers.contains(where: { $0.isUnhealthy || $0.state == "restarting" || $0.state == "dead" }) { return .red }
        if containers.contains(where: { $0.exitCode.map { !IncidentDetector.quietExitCodes.contains($0) } ?? false }) { return .orange }
        return running == 0 ? Color.secondary.opacity(0.4) : .green
    }
}

struct ContainerRow: View {
    @Environment(MonitorModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let container: Container

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: container.composeService ?? container.name).font(.callout).lineLimit(1)
                Text(verbatim: container.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if model.busy.contains(container.id) {
                ProgressView().controlSize(.small)
            }
            Text(verbatim: container.ports.map { String($0.hostPort) }.joined(separator: " "))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Menu {
                Button("Logs") { NSApp.activate(); openWindow(id: LogsView.windowID, value: container.id) }
                Button("Copy \(container.orbDomain)") { model.copy(container.orbDomain) }
                Divider()
                if container.isRunning {
                    Button("Stop") { model.stop(container) }
                    Button("Kill") { model.kill(container) }
                } else {
                    Button("Start") { model.start(container) }
                }
                if let dir = container.workingDir {
                    Divider()
                    Button("Show project in Finder") { model.reveal(dir) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .buttonStyle(.borderless)
        }
        .padding(.leading, 14)
    }

    private var symbol: String {
        if container.isUnhealthy || container.state == "restarting" || container.state == "dead" { return "xmark.octagon.fill" }
        if let code = container.exitCode, !IncidentDetector.quietExitCodes.contains(code) { return "xmark.circle" }
        return container.isRunning ? "circle.fill" : "circle"
    }

    private var color: Color {
        if container.isUnhealthy || container.state == "restarting" || container.state == "dead" { return .red }
        if let code = container.exitCode, !IncidentDetector.quietExitCodes.contains(code) { return .orange }
        return container.isRunning ? .green : .secondary
    }
}

/// A compose service whose port is taken: one line, the way around it on click.
struct ConflictRow: View {
    @Environment(MonitorModel.self) private var model
    let conflict: PortConflict
    @State private var expanded = false

    var body: some View {
        let claim = conflict.claim
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(verbatim: String(claim.hostPort))
                    .font(.callout.monospacedDigit().weight(.medium))
                    .frame(width: 48, alignment: .leading)
                Text(verbatim: claim.service).font(.callout).lineLimit(1)
                Text(verbatim: claim.project).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Text(verbatim: "← " + holderText).font(.caption).foregroundStyle(.orange).lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }

            if expanded { details(claim) }
        }
    }

    private func details(_ claim: PortClaim) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Taken by \(holderText)").foregroundStyle(.orange)
            if !conflict.runningOn.isEmpty {
                Text("Running remapped on \(conflict.runningOn.map(String.init).joined(separator: ", "))")
                    .foregroundStyle(.secondary)
            }
            if conflict.isAirPlay {
                HStack(spacing: 4) {
                    Text("macOS AirPlay Receiver listens here.").foregroundStyle(.secondary)
                    Button("Settings…") { model.openAirPlaySettings() }.buttonStyle(.link)
                }
            } else {
                HStack(spacing: 4) {
                    Text("OrbStack, no port needed:").foregroundStyle(.secondary)
                    if claim.looksLikeHTTP {
                        Button { model.openURL(claim.orbURL) } label: {
                            Text(verbatim: claim.orbAddress).lineLimit(1).truncationMode(.middle)
                        }
                        .buttonStyle(.link)
                        .help("Open in browser")
                    } else {
                        Text(verbatim: claim.orbAddress).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Button { model.copy(claim.looksLikeHTTP ? claim.orbURL : claim.orbAddress) } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless).help("Copy")
                }
            }
            Text(verbatim: claim.files.map { ($0 as NSString).lastPathComponent }.joined(separator: " + "))
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(.leading, 56)
    }

    private var holderText: String {
        conflict.holders.map { holder in
            let name: String
            if case .container(let c) = holder.owner { name = c.composeService ?? c.name } else { name = holder.ownerName }
            return holder.project.map { "\(name) · \($0)" } ?? name
        }.joined(separator: ", ")
    }
}

extension PortClaim {
    var orbAddress: String { "\(service).\(project).orb.local:\(containerPort)" }

    /// Database and broker ports speak their own protocols; a browser link there is noise.
    var looksLikeHTTP: Bool {
        ![5432, 3306, 6379, 27017, 9000, 9092, 9093, 2181, 5672, 1433, 11211].contains(containerPort)
    }
}

/// Registers the app as a login item through SMAppService (like Tandem).
struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Launch at login", isOn: $enabled)
            .toggleStyle(.checkbox)
            .font(.caption)
            .onChange(of: enabled) { _, on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    enabled = SMAppService.mainApp.status == .enabled
                }
            }
    }
}
