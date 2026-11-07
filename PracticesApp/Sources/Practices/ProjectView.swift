import SwiftUI
import AppKit
import PracticesCore

/// A project (`design/Project.dc.html`): name and description, the kv-block, the projects inside
/// it, its repositories with the state of their clones, its own services in three columns.
struct ProjectView: View {
    @Environment(RegistryModel.self) private var registry
    let project: Project
    /// Links are read from the cards' `links.yaml`, once per change of the services.
    @State private var catalogue: Catalogue?

    var body: some View {
        let services = registry.services(of: project)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: project.name).font(Theme.ui(17, .semibold))
                    if let dir = workdir {
                        Text(verbatim: short(dir.path)).font(Theme.mono(12)).foregroundStyle(Theme.Color.textMuted).lineLimit(1).truncationMode(.head)
                    }
                    if let description = project.description {
                        Text(verbatim: description).font(Theme.ui(13)).foregroundStyle(Theme.Color.textSecondary).textSelection(.enabled)
                    }
                }
                kv(services)
                nested
                repositories
                columns(services)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbarTrailing { toolbar }
        .task(id: project.id) { await registry.loadGitStates(of: project) }
        .task(id: registry.services) { catalogue = try? registry.registry.catalogue() }
    }

    // MARK: kv-block

    private func kv(_ services: [Service]) -> some View {
        let links = linkCounts()
        var repos: [(String, Color)] = [("\(project.repos.count)", Theme.Color.text)]
        for (i, role) in project.repos.compactMap(\.role).enumerated() {
            repos += [(i == 0 ? " · " : ", ", Theme.Color.text), (role, roleClass(role).color)]
        }
        var kinds: [(String, Color)] = [("\(services.count)", Theme.Color.text)]
        for c in ServiceClass.allCases {
            let n = services.filter { ServiceClass(for: $0) == c }.count
            if n > 0 { kinds += [(" · ", Theme.Color.text), ("\(n) \(c.rawValue)", c.color)] }
        }
        return KVBlock {
            KVRow("id", project.id)
            if let parent = project.parent {
                KVRow("parent") {
                    Button { registry.selection = .project(parent) } label: {
                        Text(verbatim: parent).foregroundStyle(registry.zoneColor(of: parent))
                    }
                    .buttonStyle(.plain)
                }
            }
            KVRow("repos") { coloured(repos) }
            KVRow("services") { coloured(kinds) }
            KVRow("links") {
                FlowRow {
                    Text(verbatim: "\(links.out.reduce(0) { $0 + $1.n }) наружу →")
                    ForEach(links.out, id: \.project) { out in
                        let color = registry.zoneColor(of: out.project)
                        Button { registry.selection = .project(out.project) } label: {
                            Text(verbatim: "\(out.project) \(out.n)").font(Theme.mono(11)).foregroundStyle(color)
                                .padding(.horizontal, 7).padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    Text(verbatim: "· \(links.inside) внутри").foregroundStyle(Theme.Color.textMuted)
                }
                .alignmentGuide(.firstTextBaseline) { $0[.top] + 11.5 }
            }
            KVRow("mcp") {
                Text(verbatim: "get_project \(project.id) · scan_links \(project.id)").foregroundStyle(Theme.Color.textSecondary)
            }
        }
    }

    /// Text in several colours on one line.
    private func coloured(_ parts: [(String, Color)]) -> some View {
        HStack(spacing: 0) {
            ForEach(parts.indices, id: \.self) { Text(verbatim: parts[$0].0).foregroundStyle(parts[$0].1) }
        }
        .lineLimit(1)
    }

    private func roleClass(_ role: String?) -> ServiceClass {
        switch role {
        case "frontend": .front
        case "backend": .api
        default: .other
        }
    }

    /// Links from this project's own services to other projects, by project; and links between its own.
    private func linkCounts() -> (out: [(project: String, n: Int)], inside: Int) {
        guard let c = catalogue else { return ([], 0) }
        let projectOf = Dictionary(c.services.map { ($0.id, $0.project) }, uniquingKeysWith: { a, _ in a })
        var out: [String: Int] = [:], inside = 0
        for l in c.links where projectOf[l.from] == project.id {
            guard let to = projectOf[l.link.to] else { continue }
            if to == project.id { inside += 1 } else { out[to, default: 0] += 1 }
        }
        return (out.map { (project: $0.key, n: $0.value) }.sorted { ($1.n, $0.project) < ($0.n, $1.project) }, inside)
    }

    @ViewBuilder private var nested: some View {
        if let children = registry.childProjects[project.id], !children.isEmpty {
            FlowRow {
                Text(verbatim: "Вложенные:").font(Theme.ui(11)).foregroundStyle(Theme.Color.textMuted)
                ForEach(children) { child in
                    Button { registry.selection = .project(child.id) } label: { Chip(child.id, color: registry.zoneColor(of: child.id)) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Repositories

    private var repositories: some View {
        SectionCard("Репозитории") {
            ForEach(project.repos, id: \.repo) { entry in
                let clone = registry.clones[entry.repo]
                HStack(spacing: 10) {
                    if let role = entry.role { badge(role, roleClass(role)) }
                    Button { if let url = URL(string: "https://\(entry.repo)") { NSWorkspace.shared.open(url) } } label: {
                        Text(verbatim: entry.repo.description).foregroundStyle(Theme.Color.text)
                    }
                    .buttonStyle(.plain).help("Open on the hosting")
                    if let clone {
                        Text(verbatim: short(clone)).foregroundStyle(Theme.Color.textMuted).truncationMode(.head)
                    } else {
                        Text(verbatim: "не склонирован").foregroundStyle(Theme.Color.warn)
                    }
                    Spacer(minLength: 0)
                    if let state = registry.gitStates[entry.repo] { git(state) }
                }
                .font(Theme.mono(12)).lineLimit(1)
            }
            // Code without git: its place on this machine is in `local.yaml`.
            ForEach(project.folders, id: \.self) { folder in
                let path = folderPath(folder)
                HStack(spacing: 10) {
                    badge("папка", .other)
                    Text(verbatim: folder.name).foregroundStyle(Theme.Color.text)
                    if let path {
                        Text(verbatim: short(path)).foregroundStyle(Theme.Color.textMuted).truncationMode(.head)
                    } else {
                        Text(verbatim: "нет пути в local.yaml").foregroundStyle(Theme.Color.warn)
                    }
                    Spacer(minLength: 0)
                }
                .font(Theme.mono(12)).lineLimit(1)
            }
            if project.repos.isEmpty && project.folders.isEmpty {
                EmptyState(glyph: "▢", tint: ServiceClass.worker.color, title: "Репозиториев нет",
                           text: "Проект описан, но к нему не привязан ни один клон. Заберите репозиторий из «Не распределено».",
                           code: "practicesctl assign <repo> \(project.id)") {
                    StateButton("Не распределено") { registry.selection = .unassigned }
                }
            }
        }
    }

    /// `main  2 незакоммиченных ↑1  6 нояб.`: as the clone stands, nothing fetched.
    @ViewBuilder private func git(_ state: GitState) -> some View {
        let parts = [state.uncommitted > 0 ? ru(state.uncommitted, "незакоммиченный", "незакоммиченных", "незакоммиченных") : nil,
                     (state.ahead ?? 0) > 0 ? "↑\(state.ahead!)" : nil,
                     (state.behind ?? 0) > 0 ? "↓\(state.behind!)" : nil].compactMap { $0 }
        Text(verbatim: state.branch ?? "HEAD").foregroundStyle(Theme.Color.textSecondary)
        Text(verbatim: parts.isEmpty ? "чисто" : parts.joined(separator: " "))
            .foregroundStyle(parts.isEmpty ? Theme.Color.textSecondary : Theme.Color.warn)
            .help(state.ahead == nil ? String(localized: "No upstream") : String(localized: "Ahead of and behind its upstream, as the last fetch left it"))
        if let date = state.lastCommit {
            Text(verbatim: date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "ru_RU"))))
                .foregroundStyle(Theme.Color.textMuted).help(state.subject ?? "")
        }
    }

    /// A badge with free text in a class colour: the role of a repository, the kind of a service.
    private func badge(_ text: String, _ kind: ServiceClass) -> some View {
        Text(verbatim: text).font(Theme.mono(10.5)).foregroundStyle(kind.color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(kind.rgbBadgeBackground, in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }

    // MARK: Services

    private func columns(_ services: [Service]) -> some View {
        let byColumn = Dictionary(grouping: services, by: ServiceMap.column(of:))
        return HStack(alignment: .top, spacing: 12) {
            column(.front, "Фронты", byColumn[.front] ?? []) { EmptyView() }
            column(.api, "API и воркеры", byColumn[.api] ?? []) { EmptyView() }
            column(.data, "Данные", byColumn[.data] ?? []) { conditions(services) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func column<Footer: View>(_ column: ServiceMap.Column, _ title: String, _ services: [Service],
                                      @ViewBuilder footer: () -> Footer) -> some View {
        let color = ServiceClass(rawValue: column.rawValue)!.color
        return VStack(alignment: .leading, spacing: 6) {
            if services.isEmpty {
                EmptyState(glyph: "◌", tint: color, title: "\(title) · 0",
                           text: column == .front
                               ? "Фронт появится, когда в репозитории найдётся package.json с dev-сервером — или добавьте сервис вручную."
                               : "Появится из скана compose (practicesctl scan \(project.id) --write) — или добавьте сервис вручную.")
            } else {
                SectionTitle("\(title) · \(services.count)", color: color).padding(.bottom, 4)
                ForEach(services) { row($0, dot: color) }
            }
            Spacer(minLength: 0)
            footer()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.35)))
    }

    private func row(_ service: Service, dot: Color) -> some View {
        Button { registry.selection = .service(service.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(dot).frame(width: 7, height: 7)
                    Text(verbatim: service.id).font(Theme.mono(12, .semibold)).foregroundStyle(Theme.Color.text).lineLimit(1)
                    badge(service.kind, ServiceClass(for: service))
                    if !service.conditionIDs.isEmpty {
                        Text(verbatim: "⚑").font(Theme.ui(11)).foregroundStyle(Theme.Color.warn).help(service.conditionIDs.joined(separator: ", "))
                    }
                }
                Text(verbatim: [service.name, service.description].compactMap { $0 }.joined(separator: " — "))
                    .font(Theme.ui(11)).foregroundStyle(Theme.Color.textSecondary).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Color.cardBg, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Color.borderCard))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// `⚑ <id> — <hint>; требуют a, b, c` for every condition the project's services need.
    private func conditions(_ services: [Service]) -> some View {
        var seen = Set<String>()
        let ids = services.flatMap(\.conditionIDs).filter { seen.insert($0).inserted }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(ids, id: \.self) { id in
                let condition = registry.condition(id)
                let users = services.filter { $0.conditionIDs.contains(id) }.map { shortID($0.id) }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(verbatim: "⚑").foregroundStyle(Theme.Color.warn)
                    Text(verbatim: id + ((condition?.hint ?? condition?.name).map { " — " + $0 } ?? "") + "; требуют " + users.joined(separator: ", "))
                        .foregroundStyle(Theme.Color.textMuted)
                }
                .font(Theme.ui(11))
            }
        }
    }

    /// `device-analysis-clickhouse` → `clickhouse` inside `device-analysis`.
    private func shortID(_ id: String) -> String {
        id.hasPrefix(project.id + "-") ? String(id.dropFirst(project.id.count + 1)) : id
    }

    // MARK: Toolbar

    // "Open" is all the app does with a repository (DECISIONS 17).

    private static let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
    /// The editor is offered only when it is installed.
    private static let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")

    /// The first clone, else the first folder without git: what Finder, Terminal and VS Code open.
    private var workdir: URL? {
        (project.repos.lazy.compactMap { registry.clones[$0.repo] }.first ?? project.folders.lazy.compactMap(folderPath).first)
            .map { URL(fileURLWithPath: $0) }
    }

    @ViewBuilder private var toolbar: some View {
        let dir = workdir
        Button { registry.map.open(project: project.id); registry.selection = .map } label: { Text(verbatim: "Карта") }
        Button { if let dir { NSWorkspace.shared.open(dir) } } label: { Text(verbatim: "Finder") }
            .disabled(dir == nil).help("Show in Finder")
        if let terminal = Self.terminal {
            Button { if let dir { NSWorkspace.shared.open([dir], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) } } label: { Text(verbatim: "Terminal") }
                .disabled(dir == nil).help("Open in Terminal")
        }
        if let editor = Self.editor {
            Button { if let dir { NSWorkspace.shared.open([dir], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration()) } } label: { Text(verbatim: "VS Code") }
                .disabled(dir == nil).help("Open in Visual Studio Code")
        }
        if let repo = project.repos.first?.repo {
            Button { if let url = URL(string: "https://\(repo)") { NSWorkspace.shared.open(url) } } label: {
                Text(verbatim: repo.description.hasPrefix("github.com/") ? "GitHub ↗" : "GitLab ↗")
            }
        }
        Menu { ProjectMenuItems(id: project.id) } label: { Text(verbatim: "…") }
            .menuIndicator(.hidden).fixedSize()
            .help(Text(verbatim: "Ещё действия"))
    }

    private func folderPath(_ folder: Project.Folder) -> String? {
        registry.registry.local.folders[folder.name].map { ($0 as NSString).expandingTildeInPath }
    }

    private func short(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// The project's rare and destructive actions: the toolbar's «…» and the sidebar row's context menu
/// (`design/ProjectMenus.dc.html`). «Переименовать…» and «Перенести в проект…» wait for a registry operation.
struct ProjectMenuItems: View {
    @Environment(RegistryModel.self) private var registry
    let id: String

    var body: some View {
        Button { Task { await registry.scanLinks(of: id) } } label: { Text(verbatim: "Связи из кода") }
        Divider()
        let nested = !(registry.childProjects[id] ?? []).isEmpty
        Button(role: .destructive) { registry.removalCandidate = id } label: {
            Text(verbatim: nested ? "Удалить проект… (сначала вложенные)" : "Удалить проект…").foregroundStyle(Theme.Color.error)
        }
        .disabled(nested)
    }
}

/// Views in a row that wraps: the link chips, the nested projects.
private struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, point) in arrange(bounds.width, subviews).points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (points, CGSize(width: maxX, height: y + rowHeight))
    }
}

/// `space / parent / project` — each part a way back (DECISIONS 23: the path is for display).
/// ServiceView uses it.
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
