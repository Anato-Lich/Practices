import SwiftUI
import PracticesCore

/// «Не распределено»: repositories of the spaces' hosting and local clones that no project
/// has. The list decides nothing (DECISIONS 15) and is asked for by hand: it calls `gh` and
/// `glab` (DECISIONS 16).
struct UnassignedView: View {
    @Environment(RegistryModel.self) private var registry
    @State private var showIgnored = false

    var body: some View {
        Group {
            if registry.loadingUnassigned {
                ProgressView("Asking gh and glab…")
            } else if let repos = registry.unassigned {
                let shown = repos.filter { showIgnored || !$0.ignored }
                List {
                    Section {
                        ForEach(shown, id: \.repo) { row($0) }
                        if shown.isEmpty { Text("Every repository is in a project or ignored").foregroundStyle(.secondary) }
                    } footer: {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(registry.unassignedProblems, id: \.self) { problem in
                                Text("Could not list \(problem)").foregroundStyle(.orange)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Unassigned", systemImage: "questionmark.folder")
                } description: {
                    Text("Repositories of the spaces' hosting (through gh and glab) and local clones that are in no project. Nothing is asked until you load the list.")
                } actions: {
                    Button("Load") { Task { await registry.loadUnassigned() } }
                }
            }
        }
        .navigationTitle("Unassigned")
        .toolbarTrailing {
            Toggle("Show ignored", isOn: $showIgnored).toggleStyle(.checkbox)
            Button { Task { await registry.loadUnassigned() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(registry.loadingUnassigned)
        }
    }

    private func row(_ repo: RepoInfo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(verbatim: repo.repo.description).font(.callout.monospaced()).textSelection(.enabled)
                    if repo.archived { Chip(text: String(localized: "archived"), tint: .orange) }
                    if repo.ignored { Chip(text: String(localized: "ignored")) }
                    if repo.space == nil { Chip(text: String(localized: "local only")) }
                }
                if let description = repo.description { Text(verbatim: description).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                HStack(spacing: 10) {
                    if let date = repo.lastActivity { Text("active \(date.formatted(date: .abbreviated, time: .omitted))") }
                    if let project = repo.suggestedProject { Text("suggested: \(project)") }
                    if let clone = repo.clone { Text(verbatim: clone.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.head) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Assign") {
                ForEach(registry.projects) { project in
                    Button(registry.projectPaths[project.id] ?? project.id) { Task { await registry.assign(repo.repo, to: project.id) } }
                }
            }
            .fixedSize()
            // The space that ignores it is the one whose hosting lists it; a clone no hosting
            // lists has none, so the user says which.
            if repo.ignored {
                Button("Stop ignoring") {
                    guard let space = registry.spaces.first(where: { $0.ignore.contains(repo.repo) }) else { return }
                    Task { await registry.ignore(repo.repo, in: space.id, false) }
                }
            } else if let space = repo.space {
                Button("Ignore") { Task { await registry.ignore(repo.repo, in: space) } }
            } else {
                Menu("Ignore") {
                    ForEach(registry.spaces) { space in
                        Button(space.name) { Task { await registry.ignore(repo.repo, in: space.id) } }
                    }
                }
                .fixedSize()
            }
        }
        .padding(.vertical, 2)
    }
}
