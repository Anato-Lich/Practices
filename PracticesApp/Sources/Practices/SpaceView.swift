import SwiftUI
import AppKit
import PracticesCore

/// A space (`design/Main.dc.html`): four stat tiles, the zones of grouped projects, standalone
/// projects, the legend; on the right the shared services, the conditions and the hosting.
/// The toolbar buttons (Карта, Проверить всё) are the shell's.
struct SpaceView: View {
    @Environment(RegistryModel.self) private var registry
    let space: Space
    /// Links are read from the cards' `links.yaml`, once per change of the services.
    @State private var catalogue: Catalogue?

    var body: some View {
        let tops = registry.topProjects.filter { $0.space == space.id }
        let groups = tops.filter { registry.childProjects[$0.id] != nil }
        let standalone = tops.filter { registry.childProjects[$0.id] == nil }
        let hubs = hubs()
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                stats(groups: groups.count, hubs: hubs.count)
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let first = groups.first { zone(first) }
                        ForEach(Array(stride(from: 1, to: groups.count, by: 2)), id: \.self) { i in
                            HStack(alignment: .top, spacing: 12) {
                                zone(groups[i])
                                if i + 1 < groups.count { zone(groups[i + 1]) } else { Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
                            }
                        }
                        if !standalone.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                SectionTitle("Отдельные проекты · \(standalone.count)")
                                cards(standalone)
                            }
                        }
                        legend
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(spacing: 12) {
                        hubsCard(hubs)
                        conditionsCard
                        hostingCard
                    }
                    .frame(width: 300)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
        }
        .task(id: registry.services) { catalogue = try? registry.registry.catalogue() }
    }

    // MARK: Stats

    private func stats(groups: Int, hubs: Int) -> some View {
        let projects = registry.projects.filter { $0.space == space.id }
        let repos = projects.reduce(0) { $0 + $1.repos.count }
        let services = registry.services.filter { $0.space == space.id }
        let ids = Set(services.map(\.id))
        let links = catalogue?.links.filter { ids.contains($0.from) }.count
        return HStack(spacing: 10) {
            tile(projects.count, word(projects.count, "проект", "проекта", "проектов") + " · " + ru(groups, "группа", "группы", "групп"), nil)
            tile(repos, word(repos, "репозиторий", "репозитория", "репозиториев") + " · "
                 + ru(space.ignore.count, "игнорируется", "игнорируются", "игнорируются"), .unassigned)
            tile(services.count, word(services.count, "сервис", "сервиса", "сервисов") + " · "
                 + ru(registry.conditions[space.id]?.count ?? 0, "условие", "условия", "условий"), .map, color: ServiceClass.api.color)
            tile(links, word(links ?? 0, "связь", "связи", "связей") + " · " + ru(hubs, "общий сервис", "общих сервиса", "общих сервисов"),
                 .map, color: ServiceClass.data.color)
        }
    }

    private func tile(_ n: Int?, _ label: String, _ target: MainWindow.SidebarItem?, color: Color = Theme.Color.text) -> some View {
        Button { if let target { registry.selection = target } } label: {
            StatTile(n.map(String.init) ?? "…", label, color: color).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The plural word without its number: `ru` gives «22 проекта».
    private func word(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        String(ru(n, one, few, many).drop { $0 != " " }.dropFirst())
    }

    // MARK: Zones

    /// A top-level project holding others: a dashed frame in its zone colour, its children inside.
    private func zone(_ top: Project) -> some View {
        let color = registry.zoneColor(of: top.id)
        let children = registry.childProjects[top.id] ?? []
        let subtree = Set(registry.projects.filter { registry.path(of: $0.id).contains(top) }.map(\.id))
        let services = registry.services.filter { subtree.contains($0.project) }.count
        return VStack(alignment: .leading, spacing: 8) {
            Button { registry.selection = .project(top.id) } label: {
                HStack(spacing: 8) {
                    Text(verbatim: top.id).font(Theme.mono(13, .semibold)).foregroundStyle(color)
                    Text(verbatim: [top.name, ru(children.count, "проект", "проекта", "проектов"), ru(services, "сервис", "сервиса", "сервисов")]
                        .joined(separator: " · "))
                        .font(Theme.ui(13)).foregroundStyle(Theme.Color.textSecondary).lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            cards(children)
        }
        .padding(.top, 10).padding(.horizontal, 12).padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
    }

    private func cards(_ projects: [Project]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 140), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 10) {
            ForEach(projects) { card($0) }
        }
    }

    /// 140 × 80: id, name, the composition bar, «N серв · M репо».
    private func card(_ project: Project) -> some View {
        let services = registry.services(of: project)
        let parts = ServiceClass.allCases.map { c in (c, services.filter { ServiceClass(for: $0) == c }.count) }
        return Button { registry.selection = .project(project.id) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: project.id).font(Theme.mono(12, .semibold)).foregroundStyle(Theme.Color.text)
                Text(verbatim: project.name).font(Theme.ui(11)).foregroundStyle(Theme.Color.textSecondary)
                Spacer(minLength: 0)
                CompositionBar(parts)
                Text(verbatim: "\(services.count) серв · \(project.repos.count) репо").font(Theme.mono(10.5)).foregroundStyle(Theme.Color.textMuted)
            }
            .lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(width: 140, height: 80, alignment: .topLeading)
            .background(Theme.Color.cardBg, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Color.borderCard))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var legend: some View {
        let classes: [(ServiceClass, String)] = [(.front, "front"), (.api, "api"), (.data, "data"), (.bus, "bus"), (.hw, "hw"), (.ext, "external"), (.other, "other")]
        return HStack(spacing: 12) {
            ForEach(classes, id: \.0) { item in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(item.0.color).frame(width: 8, height: 8)
                    Text(verbatim: item.1)
                }
            }
        }
        .font(Theme.mono(10.5)).foregroundStyle(Theme.Color.textMuted)
    }

    // MARK: Right column

    /// Services of the space with at least `ServiceMap.hubCallers` distinct callers, or tagged `shared`.
    private func hubs() -> [(service: Service, callers: Int)] {
        var callers: [String: Set<String>] = [:]
        for l in catalogue?.links ?? [] { callers[l.link.to, default: []].insert(l.from) }
        return registry.services.filter { $0.space == space.id }
            .map { (service: $0, callers: callers[$0.id]?.count ?? 0) }
            .filter { $0.callers >= ServiceMap.hubCallers || $0.service.tags.contains("shared") }
            .sorted { ($1.callers, $0.service.id) < ($0.callers, $1.service.id) }
    }

    private func hubsCard(_ hubs: [(service: Service, callers: Int)]) -> some View {
        SectionCard("Общие сервисы · кто вызывает") {
            ForEach(hubs, id: \.service.id) { hub in
                let kind = ServiceClass(for: hub.service)
                Button { registry.selection = .service(hub.service.id) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(verbatim: hub.service.id).font(Theme.mono(12)).foregroundStyle(Theme.Color.text).lineLimit(1)
                            KindBadge(kind)
                            Spacer(minLength: 0)
                            Text(verbatim: "\(hub.callers)").font(Theme.mono(11)).foregroundStyle(Theme.Color.textSecondary)
                        }
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 2).fill(kind.color).opacity(0.8)
                                .frame(width: geo.size.width * min(CGFloat(hub.callers) / 24, 1))
                        }
                        .frame(height: 3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if hubs.isEmpty { empty("нет") }
        }
    }

    private var conditionsCard: some View {
        // Ids are global: a service of another space may require a condition of this one.
        let rows = (registry.conditions[space.id] ?? [])
            .map { c in (id: c.id, n: registry.services.filter { $0.conditionIDs.contains(c.id) }.count) }
            .sorted { ($1.n, $0.id) < ($0.n, $1.id) }
        return SectionCard("Условия · кто требует", spacing: 6) {
            ForEach(rows, id: \.id) { row in
                HStack(spacing: 6) {
                    Text(verbatim: "⚑").foregroundStyle(Theme.Color.warn)
                    Text(verbatim: row.id).font(Theme.mono(12)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    Text(verbatim: "\(row.n)").font(Theme.mono(11)).foregroundStyle(Theme.Color.textSecondary)
                }
                .font(Theme.ui(12))
            }
            if rows.isEmpty { empty("нет") }
        }
    }

    private var hostingCard: some View {
        SectionCard("Хостинг", spacing: 6) {
            ForEach(space.hosting, id: \.self) { h in
                Button { if let url = URL(string: "https://\(h.host)/\(h.owner)") { NSWorkspace.shared.open(url) } } label: {
                    Text(verbatim: "\(h.host)/\(h.owner) ↗").font(Theme.mono(12)).foregroundStyle(Theme.Color.link).lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            if space.hosting.isEmpty { empty("нет") }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(verbatim: text).font(Theme.ui(12)).foregroundStyle(Theme.Color.textMuted)
    }
}
