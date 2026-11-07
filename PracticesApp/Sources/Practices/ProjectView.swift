import SwiftUI
import AppKit
import PracticesCore

/// A project: where it sits, the projects inside it, its repositories with the state of their
/// clones, its services and chains.
struct ProjectView: View {
    @Environment(RegistryModel.self) private var registry
    let project: Project

    var body: some View {
        let children = registry.childProjects[project.id] ?? []
        let chains = registry.chains[project.id] ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: project.name).font(.title2.weight(.semibold))
                    if let description = project.description {
                        Text(verbatim: description).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    ProjectPath(project: project.id)
                }
                if !children.isEmpty {
                    Card(title: "Projects", trailing: nil) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(children) { child in
                                row(.project(child.id), child.id, nil, child.name)
                            }
                        }
                    }
                }
                repositories
                Card(title: "Services", trailing: nil) {
                    let services = registry.services(of: project)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(services) { service in
                            row(.service(service.id), service.id, service.kind, service.name)
                        }
                        if services.isEmpty { Text("No services yet").foregroundStyle(.secondary).font(.callout) }
                    }
                }
                if !chains.isEmpty {
                    Card(title: "Chains", trailing: nil) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(chains) { chain in row(.practice(chain.ref), chain.name, nil, "") }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .navigationTitle(project.name)
        .task(id: project.id) { await registry.loadGitStates(of: project) }
    }

    /// `id [kind] name`, opening what it names.
    private func row(_ item: MainWindow.SidebarItem, _ id: String, _ kind: String?, _ name: String) -> some View {
        Button { registry.selection = item } label: {
            HStack(spacing: 8) {
                Text(verbatim: id).font(.callout.monospaced())
                if let kind { Chip(text: kind, mono: true) }
                Text(verbatim: name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Repositories

    private var repositories: some View {
        Card(title: "Repositories", trailing: nil) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(project.repos, id: \.repo) { entry in
                    let clone = registry.clones[entry.repo]
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(verbatim: entry.repo.description).font(.callout.monospaced()).textSelection(.enabled)
                                if let role = entry.role { Chip(text: role) }
                            }
                            if let clone {
                                Text(verbatim: short(clone)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                if let state = registry.gitStates[entry.repo] { git(state) }
                            } else {
                                Text("not cloned").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        if let clone { open(clone) }
                        action("Open on the hosting", "safari") { if let url = URL(string: "https://\(entry.repo)") { NSWorkspace.shared.open(url) } }
                    }
                }
                // Code without git: its place on this machine is in `local.yaml`.
                ForEach(project.folders, id: \.self) { folder in
                    let path = registry.registry.local.folders[folder.name].map { ($0 as NSString).expandingTildeInPath }
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(verbatim: folder.name).font(.callout.monospaced())
                                Chip(text: String(localized: "folder without git"))
                            }
                            if let path {
                                Text(verbatim: short(path)).font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("no path in local.yaml").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        if let path { open(path) }
                    }
                }
                if project.repos.isEmpty && project.folders.isEmpty {
                    Text("No repositories").foregroundStyle(.secondary).font(.callout)
                }
            }
        }
    }

    /// `main · 3 uncommitted · ↑1 ↓2 · 5 Nov — subject`: as the clone stands, nothing fetched.
    private func git(_ state: GitState) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: state.branch ?? "detached HEAD").font(.caption.monospaced())
            if state.uncommitted > 0 { Text("\(state.uncommitted) uncommitted").foregroundStyle(.orange) }
            if let ahead = state.ahead, let behind = state.behind {
                if ahead > 0 || behind > 0 {
                    Text(verbatim: [ahead > 0 ? "↑\(ahead)" : nil, behind > 0 ? "↓\(behind)" : nil].compactMap { $0 }.joined(separator: " "))
                        .font(.caption.monospacedDigit()).foregroundStyle(behind > 0 ? .orange : .secondary)
                        .help("Ahead of and behind its upstream, as the last fetch left it")
                }
            } else if state.branch != nil {
                Text("no upstream").foregroundStyle(.tertiary)
            }
            if let date = state.lastCommit {
                Text(verbatim: "· " + date.formatted(date: .abbreviated, time: .omitted) + (state.subject.map { " — \($0)" } ?? ""))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .font(.caption)
    }

    // "Open" is all the app does with a repository (DECISIONS 17).

    private static let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
    /// The editor is offered only when it is installed.
    private static let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")

    @ViewBuilder
    private func open(_ path: String) -> some View {
        let url = URL(fileURLWithPath: path)
        action("Show in Finder", "folder") { NSWorkspace.shared.open(url) }
        if let terminal = Self.terminal {
            action("Open in Terminal", "terminal") { NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: .init()) }
        }
        if let editor = Self.editor {
            action("Open in Visual Studio Code", "chevron.left.forwardslash.chevron.right") {
                NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: .init())
            }
        }
    }

    private func action(_ help: LocalizedStringKey, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Image(systemName: icon) }.buttonStyle(.borderless).help(help)
    }

    private func short(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// `space / parent / project` — each part a way back (DECISIONS 23: the path is for display).
struct ProjectPath: View {
    @Environment(RegistryModel.self) private var registry
    let project: String

    var body: some View {
        let path = registry.path(of: project)
        HStack(spacing: 6) {
            if let space = path.first?.space {
                part(space, .space(space))
            }
            ForEach(path) { project in
                Text(verbatim: "/")
                part(project.id, .project(project.id))
            }
        }
        .font(.caption.monospaced()).foregroundStyle(.secondary)
    }

    private func part(_ text: String, _ item: MainWindow.SidebarItem) -> some View {
        Button { registry.selection = item } label: { Text(verbatim: text).underline() }.buttonStyle(.plain)
    }
}
