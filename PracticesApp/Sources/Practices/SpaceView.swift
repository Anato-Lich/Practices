import SwiftUI
import AppKit
import PracticesCore

/// A space: where its repositories are hosted, what it holds and its named conditions.
struct SpaceView: View {
    @Environment(RegistryModel.self) private var registry
    let space: Space

    var body: some View {
        let projects = registry.tree.filter { $0.project.space == space.id }
        let services = registry.services.filter { $0.space == space.id }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(verbatim: space.name).font(.title2.weight(.semibold))
                        Chip(text: space.id, mono: true)
                    }
                    Text("\(projects.count) projects · \(projects.reduce(0) { $0 + $1.project.repos.count }) repositories · \(services.count) services · \(space.ignore.count) ignored")
                        .foregroundStyle(.secondary)
                }
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 16) {
                    GridRow {
                        Card(title: "Projects", trailing: nil) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(projects, id: \.project.id) { project, depth in
                                    Button { registry.selection = .project(project.id) } label: {
                                        HStack(spacing: 8) {
                                            Text(verbatim: project.id).font(.callout.monospaced())
                                            Text(verbatim: project.name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                            Spacer()
                                            Text(verbatim: "\(project.repos.count) · \(registry.services(of: project).count)")
                                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                                .help("Repositories · services")
                                        }
                                        .padding(.leading, CGFloat(depth) * 16)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                                if projects.isEmpty { Text("No projects").foregroundStyle(.secondary).font(.callout) }
                            }
                        }
                        VStack(spacing: 16) {
                            hosting
                            conditions(services)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .navigationTitle(space.name)
    }

    private var hosting: some View {
        Card(title: "Hosting", trailing: nil) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(space.hosting, id: \.self) { hosting in
                    HStack {
                        Text(verbatim: "\(hosting.host)/\(hosting.owner)").font(.callout.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button { if let url = URL(string: "https://\(hosting.host)/\(hosting.owner)") { NSWorkspace.shared.open(url) } } label: {
                            Image(systemName: "safari")
                        }
                        .buttonStyle(.borderless).help("Open in browser")
                    }
                }
                if space.hosting.isEmpty { Text("No hosting").foregroundStyle(.secondary).font(.callout) }
            }
        }
    }

    private func conditions(_ services: [Service]) -> some View {
        Card(title: "Conditions", trailing: nil) {
            let conditions = registry.conditions[space.id] ?? []
            VStack(alignment: .leading, spacing: 10) {
                ForEach(conditions) { condition in
                    // Ids are global: a service of another space may require it too.
                    let users = registry.services.filter { $0.conditionIDs.contains(condition.id) }.map(\.id)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(verbatim: condition.name).font(.callout)
                            Chip(text: condition.id, mono: true)
                        }
                        if let hint = condition.hint { Text(verbatim: hint).font(.caption).foregroundStyle(.secondary) }
                        if !users.isEmpty {
                            Text("Required by \(users.joined(separator: ", "))").font(.caption.monospaced()).foregroundStyle(.tertiary)
                        }
                    }
                    .textSelection(.enabled)
                }
                if conditions.isEmpty { Text("No conditions").foregroundStyle(.secondary).font(.callout) }
            }
        }
    }
}
