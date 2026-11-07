import SwiftUI
import AppKit
import PracticesCore

/// «Не распределено» (`design/Unassigned.dc.html`): repositories of the spaces' hosting and
/// local clones that no project has, and `local.yaml` folders no project names. The list
/// decides nothing (DECISIONS 15) and is asked for by hand: it calls `gh` and `glab` (DECISIONS 16).
struct UnassignedView: View {
    @Environment(RegistryModel.self) private var registry
    @State private var showIgnored = false

    var body: some View {
        Group {
            if registry.loadingUnassigned {
                ProgressView { Text(verbatim: "Спрашиваю gh и glab…") }
            } else if let repos = registry.unassigned {
                content(repos)
            } else {
                ContentUnavailableView {
                    Label { Text(verbatim: "Не распределено") } icon: { Image(systemName: "questionmark.folder") }
                } description: {
                    Text(verbatim: "Репозитории хостинга пространств (через gh и glab) и локальные клоны, которых нет ни в одном проекте. Ничего не спрашивается, пока вы не нажмёте «Обновить».")
                } actions: {
                    Button { Task { await registry.loadUnassigned() } } label: { Text(verbatim: "Обновить") }
                        .buttonStyle(ToolbarButtonStyle())
                }
            }
        }
        .toolbarLeading { title }
        .toolbarTrailing {
            Toggle(isOn: $showIgnored) { Text(verbatim: "Показывать игнорируемые").font(Theme.ui(13)) }
                .toggleStyle(.checkbox).tint(Theme.Color.accent)
            Button { Task { await registry.loadUnassigned() } } label: {
                Label { Text(verbatim: "Обновить") } icon: { Image(systemName: "arrow.clockwise") }
            }
            .disabled(registry.loadingUnassigned)
        }
    }

    private var title: some View {
        let hosting = registry.spaces.flatMap(\.hosting)
        let gh = hosting.filter { $0.host.lowercased() == "github.com" }.count
        let roots = registry.registry.searchRoots.map { ($0 as NSString).abbreviatingWithTildeInPath }
        return HStack(spacing: 12) {
            Text(verbatim: "Не распределено").font(Theme.ui(15, .semibold)).foregroundStyle(Theme.Color.text)
            Text(verbatim: "gh: " + ru(gh, "организация", "организации", "организаций")
                 + " · glab: " + ru(hosting.count - gh, "группа", "группы", "групп")
                 + " · клоны: " + roots.joined(separator: ", "))
                .font(Theme.mono(12)).foregroundStyle(Theme.Color.textSecondary).lineLimit(1).truncationMode(.tail)
        }
    }

    // MARK: Content

    private func content(_ repos: [RepoInfo]) -> some View {
        let free = repos.filter { !$0.ignored }
        let ignored = repos.count - free.count
        let shown = repos.filter { showIgnored || !$0.ignored }.sorted { !$0.ignored && $1.ignored }
        let folders = unassignedFolders
        let heading = !showIgnored ? "Без проекта" : free.isEmpty ? "Игнорируемые" : "Без проекта и игнорируемые"
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    StatTile(String(free.count), free.isEmpty ? "без проекта — всё распределено" : "без проекта",
                             color: free.isEmpty ? Theme.Color.ok : Theme.Color.warn)
                    StatTile(String(ignored), "игнорируется")
                    StatTile(String(folders.count), "папки без git никуда не отнесены",
                             color: folders.isEmpty ? Theme.Color.text : Theme.Color.warn)
                }

                VStack(alignment: .leading, spacing: 0) {
                    SectionTitle("\(heading) · показаны \(shown.count) из \(repos.count)")
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .bottom) { Theme.Color.borderCard.frame(height: 1) }
                    ForEach(shown, id: \.repo) { row($0) }
                    if shown.isEmpty {
                        Text(verbatim: "Каждый репозиторий в проекте или игнорируется").font(Theme.ui(12))
                            .foregroundStyle(Theme.Color.textMuted).padding(.horizontal, 14).padding(.vertical, 10)
                    }
                }
                .background(Theme.Color.cardBg, in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.Color.borderCard))

                ForEach(registry.unassignedProblems, id: \.self) { problem in
                    Text(verbatim: "Не удалось получить список: " + problem).font(Theme.mono(11)).foregroundStyle(Theme.Color.warn)
                }

                if !folders.isEmpty { foldersCard(folders) }

                Text(verbatim: "Список ничего не решает (DECISIONS 15): проект назначаете вы, подгруппа GitLab — только подсказка имени. gh и glab вызываются только по кнопке «Обновить».")
                    .font(Theme.ui(11)).foregroundStyle(Theme.Color.textMuted)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
        }
    }

    private func row(_ repo: RepoInfo) -> some View {
        let host = String(repo.repo.description.prefix { $0 != "/" })
        let github = host == "github.com"
        return HStack(spacing: 12) {
            Text(verbatim: github ? "github" : "gitlab").font(Theme.mono(10))
                .foregroundStyle(github ? Theme.Color.textChip : Theme.Color.warn)
                .frame(width: 52).padding(.vertical, 2)
                .background(github ? Color(hex: 0x9A9AA3, alpha: 0.16) : Theme.Color.warn.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(verbatim: repo.repo.description).font(Theme.mono(12)).foregroundStyle(Theme.Color.text).textSelection(.enabled)
                    if repo.archived { RepoChip(text: "archived", color: Theme.Color.warn) }
                    if repo.ignored { RepoChip(text: "ignored", color: Theme.Color.textMuted) }
                }
                if let description = repo.description, !description.isEmpty {
                    Text(verbatim: description).font(Theme.ui(12)).foregroundStyle(Theme.Color.textSecondary).lineLimit(2)
                }
                Text(verbatim: meta(repo)).font(Theme.mono(10.5)).foregroundStyle(Theme.Color.textMuted)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            projectMenu { project in Task { await registry.assign(repo.repo, to: project) } }
            ignoreButton(repo)
            Button { if let url = URL(string: "https://" + repo.repo.description) { NSWorkspace.shared.open(url) } } label: {
                Text(verbatim: "↗").frame(width: 10)    // + padding 10 · 2 = the design's 30
            }
            .buttonStyle(CompactButtonStyle(fontSize: 12))
            .help(Text(verbatim: "Открыть на хостинге"))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Theme.Color.borderSoft.frame(height: 1) }
    }

    /// Only what the model knows: last activity, the GitLab subgroup as a suggestion, the clone.
    private func meta(_ repo: RepoInfo) -> String {
        var parts: [String] = []
        if let date = repo.lastActivity {
            parts.append("активен " + date.formatted(.dateTime.day().month(.abbreviated).year().locale(Locale(identifier: "ru_RU"))))
        }
        if let project = repo.suggestedProject { parts.append("подгруппа: " + project) }
        parts.append(repo.clone.map { "клон " + ($0 as NSString).abbreviatingWithTildeInPath } ?? "клона нет")
        return parts.joined(separator: " · ")
    }

    private func projectMenu(_ assign: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(registry.projects) { project in
                Button(registry.projectPaths[project.id] ?? project.id) { assign(project.id) }
            }
        } label: {
            HStack(spacing: 4) { Text(verbatim: "В проект"); Text(verbatim: "▾").font(.system(size: 9)) }
        }
        .menuStyle(.button).menuIndicator(.hidden)
        .buttonStyle(CompactButtonStyle(fontSize: 12))
        .fixedSize()
    }

    // The space that ignores it is the one whose hosting lists it; a clone no hosting lists has
    // none, so the user says which.
    @ViewBuilder private func ignoreButton(_ repo: RepoInfo) -> some View {
        if repo.ignored {
            Button {
                guard let space = registry.spaces.first(where: { $0.ignore.contains(repo.repo) }) else { return }
                Task { await registry.ignore(repo.repo, in: space.id, false) }
            } label: { Text(verbatim: "Не игнорировать") }
            .buttonStyle(CompactButtonStyle(fontSize: 12))
        } else if let space = repo.space {
            Button { Task { await registry.ignore(repo.repo, in: space) } } label: { Text(verbatim: "Игнорировать") }
                .buttonStyle(CompactButtonStyle(fontSize: 12))
        } else {
            Menu {
                ForEach(registry.spaces) { space in
                    Button(space.name) { Task { await registry.ignore(repo.repo, in: space.id) } }
                }
            } label: { Text(verbatim: "Игнорировать") }
            .menuStyle(.button).menuIndicator(.hidden)
            .buttonStyle(CompactButtonStyle(fontSize: 12))
            .fixedSize()
        }
    }

    // MARK: Folders

    /// `local.yaml` folders (code without git) that no project lists.
    private var unassignedFolders: [(name: String, path: String)] {
        let named = Set(registry.projects.flatMap(\.folders).map(\.name))
        return registry.registry.local.folders.filter { !named.contains($0.key) }
            .map { (name: $0.key, path: ($0.value as NSString).abbreviatingWithTildeInPath) }
            .sorted { $0.path < $1.path }
    }

    private func foldersCard(_ folders: [(name: String, path: String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Папки без git · local.yaml", color: Theme.Color.warn).padding(.bottom, 2)
            ForEach(folders.indices, id: \.self) { i in
                let folder = folders[i]
                HStack(spacing: 12) {
                    Text(verbatim: folder.path).foregroundStyle(Theme.Color.text)
                    if (folder.path as NSString).lastPathComponent != folder.name {
                        Text(verbatim: folder.name).foregroundStyle(Theme.Color.textMuted)
                    }
                    Spacer(minLength: 0)
                    // No «В проект ▾»: Registry can assign a repository, not a folder.
                }
                .font(Theme.mono(12))
                .frame(minHeight: 24)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.warn.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.Color.warn.opacity(0.35)))
    }
}

/// Repository chip: mono 10.5, padding 1 6, radius 4, 1px border in its colour.
private struct RepoChip: View {
    let text: String
    let color: Color
    var body: some View {
        Text(verbatim: text).font(Theme.mono(10.5)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color, lineWidth: 1))
            .fixedSize()
    }
}
