import SwiftUI
import AppKit
import PracticesCore

/// «Настройка» (`design/Settings.dc.html`): what is personal to this machine (DECISIONS 36) —
/// spaces (local repositories, never shared), roots, agents, the environment. Failures go to the error bar.
struct SettingsView: View {
    @Environment(RegistryModel.self) private var registry
    @State private var adding = false
    @State private var scope: InstructionScope?

    var body: some View {
        let setup = registry.setup
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                spaces(setup.status)
                HStack(alignment: .top, spacing: 12) {
                    clones(setup.status).frame(maxWidth: .infinity)
                    agents(setup.status).frame(maxWidth: .infinity)
                }
                environment(setup.status)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
        }
        .task { await setup.refresh() }
        .toolbarLeading {
            HStack(spacing: 12) {
                Breadcrumb(prefix: "~/.practices/", title: "Настройка", monoTitle: false)
                Text(verbatim: "всё личное: не в git и не в сборке").font(Theme.mono(12)).foregroundStyle(Theme.Color.textSecondary).lineLimit(1)
            }
        }
        .toolbarTrailing {
            Button { Task { await setup.refresh() } } label: { Text(verbatim: "Проверить") }
                .disabled(setup.busy.contains("status"))
        }
    }

    // MARK: Spaces

    private func spaces(_ status: SetupStatus?) -> some View {
        let spaces = status?.spaces ?? []
        return card("Пространства · \(spaces.count)", note: tilde(registry.registry.root.path)) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
                GridRow {
                    Text(verbatim: "id").frame(width: 110, alignment: .leading)
                    Text(verbatim: "название").frame(width: 130, alignment: .leading)
                    Text(verbatim: "путь").frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: "git").frame(width: 300, alignment: .leading)
                }
                .font(Theme.mono(10.5)).foregroundStyle(Theme.Color.textMuted).textCase(.uppercase)
                .padding(.bottom, 4)
                Theme.Color.borderCard.frame(height: 1)
                ForEach(spaces, id: \.id) { space in
                    spaceRow(space)
                    Theme.Color.borderSoft.frame(height: 1)
                }
            }
            VStack(spacing: 0) {
                if spaces.isEmpty {
                    Text(verbatim: "Пространств нет — создайте своё.").font(Theme.ui(12)).foregroundStyle(Theme.Color.textMuted)
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                }
            }
            HStack(spacing: 8) {
                Button { adding.toggle() } label: { Text(verbatim: "Создать…") }
                    .buttonStyle(ToolbarButtonStyle())
                Spacer()
                Text(verbatim: "Каталог личный: git пространства — только история и принятые правки, без remote.")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.Color.textMuted)
            }
            .padding(.top, 6)
            if adding { CreateSpaceRow() }
        }
    }

    private func spaceRow(_ space: SpaceState) -> some View {
        GridRow {
            Text(verbatim: space.id).font(Theme.mono(12)).lineLimit(1).frame(height: 34)
            Text(verbatim: space.name).font(Theme.ui(13)).lineLimit(1)
            Text(verbatim: tilde(space.path)).font(Theme.mono(11.5)).foregroundStyle(Theme.Color.textSecondary).lineLimit(1).truncationMode(.middle).help(space.path)
            gitCell(space)
        }
    }

    @ViewBuilder private func gitCell(_ space: SpaceState) -> some View {
        if let uncommitted = space.uncommitted {
            HStack(spacing: 10) {
                Text(verbatim: space.branch ?? "HEAD")
                Text(verbatim: uncommitted == 0 ? "чисто" : "\(uncommitted) не закоммичены")
                    .foregroundStyle(uncommitted == 0 ? Theme.Color.ok : Theme.Color.warn)
            }
            .font(Theme.mono(11.5)).lineLimit(1)
        } else {
            Text(verbatim: "не git-репозиторий").font(Theme.mono(11.5)).foregroundStyle(Theme.Color.warn)
        }
    }

    // MARK: Clones

    private func clones(_ status: SetupStatus?) -> some View {
        let setup = registry.setup
        let roots = status?.roots ?? []
        let n = roots.reduce(0) { $0 + $1.clones }
        let folders = registry.registry.local.folders.sorted { $0.key < $1.key }
        return card("Клоны · " + ru(roots.count, "папка", "папки", "папок") + " · " + ru(n, "клон", "клона", "клонов")) {
            Button { Task { await setup.refresh() } } label: { Text(verbatim: "Пересканировать") }
                .buttonStyle(ToolbarButtonStyle()).disabled(setup.busy.contains("status"))
        } content: {
            RootsList(status: status, note: setup.checkedAt.map { "скан " + $0.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) })
            HStack(spacing: 8) {
                Button { Task { await setup.addRoots(chooseFolders()) } } label: { Text(verbatim: "Добавить папку…") }
                    .buttonStyle(ToolbarButtonStyle())
                Text(verbatim: "local.yaml → roots").font(Theme.mono(11)).foregroundStyle(Theme.Color.textMuted)
            }
            HStack {
                SectionTitle("Папки без git")
                Spacer()
                Text(verbatim: "local.yaml → folders").font(Theme.mono(10.5)).foregroundStyle(Theme.Color.textMuted)
            }
            .padding(.top, 4)
            if folders.isEmpty {
                Text(verbatim: "нет").font(Theme.mono(12)).foregroundStyle(Theme.Color.textMuted)
            }
            ForEach(folders, id: \.key) { name, path in
                HStack(spacing: 10) {
                    Text(verbatim: name).frame(minWidth: 90, alignment: .leading)
                    Text(verbatim: tilde((path as NSString).expandingTildeInPath)).foregroundStyle(Theme.Color.textSecondary).lineLimit(1).truncationMode(.middle)
                }
                .font(Theme.mono(12)).frame(minHeight: 24)
            }
        }
    }

    // MARK: Agents

    private func agents(_ status: SetupStatus?) -> some View {
        let setup = registry.setup
        let home = SetupModel.agentHome
        let withRepos = registry.projects.filter { !$0.repos.isEmpty }
        return card("Агенты", note: "practicesctl setup agents") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
                GridRow {
                    Text(verbatim: "инструмент").frame(width: 92, alignment: .leading)
                    Text(verbatim: "MCP")
                    Text(verbatim: "блок инструкций")
                    Text(verbatim: "")
                }
                .font(Theme.mono(10.5)).foregroundStyle(Theme.Color.textMuted).textCase(.uppercase)
                .padding(.bottom, 4)
                Theme.Color.borderCard.frame(height: 1)
                ForEach(status?.tools ?? [], id: \.tool) { tool in
                    GridRow {
                        Text(verbatim: tool.tool.title).font(Theme.ui(13, .semibold)).frame(minHeight: 34)
                        if !tool.found {
                            Text(verbatim: "не найден на машине").fixedSize()
                            Text(verbatim: "—")
                        } else {
                            Text(verbatim: tool.mcp ? "✓ зарегистрирован" : "не зарегистрирован").foregroundStyle(tool.mcp ? Theme.Color.ok : Theme.Color.warn)
                                .help(tilde(home.mcpConfig(tool.tool).path)).fixedSize()
                            blockText(tool, home).fixedSize().help(home.instructions(tool.tool).map { tilde($0.path) } ?? "")
                        }
                        HStack(spacing: 6) {
                            if !tool.found {
                                Button { Task { await setup.refresh() } } label: { Text(verbatim: "Проверить снова") }
                            } else {
                                if !tool.mcp {
                                    Button { Task { await setup.setupAgents([tool.tool], instructions: false) } } label: { Text(verbatim: "Зарегистрировать") }
                                }
                                if let state = tool.instructions {
                                    Button { Task { await setup.setupAgents([tool.tool], mcp: false) } } label: {
                                        Text(verbatim: state == "absent" ? "Записать" : state == "current" ? "Записать снова" : "Обновить")
                                    }
                                    .disabled(state == "current")
                                }
                            }
                        }
                        .buttonStyle(CompactButtonStyle(height: 24, fontSize: 12))
                        .disabled(setup.busy.contains("agents"))
                    }
                    .font(Theme.mono(11.5))
                    .foregroundStyle(tool.found ? Theme.Color.text : Theme.Color.textDisabled)
                    Theme.Color.borderSoft.frame(height: 1)
                }
            }
            HStack(spacing: 10) {
                SectionTitle("Инструкции")
                Text(verbatim: status?.scope.map { $0 == .global ? "сейчас: глобально" : "сейчас: в проектах" } ?? "не настроено")
                    .font(Theme.mono(11)).foregroundStyle(status?.scope == nil ? Theme.Color.textMuted : Theme.Color.ok)
                Spacer()
            }
            .padding(.top, 4)
            let chosen = scope ?? status?.scope ?? .global
            let found = (status?.tools ?? []).filter(\.found).map(\.tool)
            ScopeSegments(scope: Binding(get: { chosen }, set: { scope = $0 }), clones: setup.projectClones)
            Button { Task { await setup.setupAgents(found, scope: chosen) } } label: { Text(verbatim: "Настроить агентов") }
                .buttonStyle(CompactButtonStyle(prominent: true, height: 24, fontSize: 12))
                .disabled(found.isEmpty || setup.busy.contains("agents") || chosen == .projects && setup.projectClones == 0)
            HStack {
                SectionTitle("В проектах")
                Spacer()
                Menu {
                    ForEach(withRepos, id: \.id) { p in
                        Button { Task { await setup.writeProject(p.id) } } label: { Text(verbatim: p.id) }
                    }
                } label: { Text(verbatim: "Записать в проект…") }
                    .menuStyle(.button).buttonStyle(CompactButtonStyle(height: 24, fontSize: 12)).menuIndicator(.hidden).fixedSize()
                    .disabled(withRepos.isEmpty || setup.busy.contains("project"))
            }
            .padding(.top, 4)
            let blocks = status?.projectBlocks ?? []
            if blocks.isEmpty {
                Text(verbatim: "Ни в одном клоне блока нет.").font(Theme.ui(12)).foregroundStyle(Theme.Color.textMuted)
            }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                HStack(spacing: 10) {
                    Text(verbatim: tilde(block.clone)).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: block.file).foregroundStyle(Theme.Color.textSecondary)
                    Spacer()
                    let date = modified(URL(fileURLWithPath: block.clone).appendingPathComponent(block.file).path)
                    Text(verbatim: block.state == "current" ? "записан · " + shortDate(date) : "устарел")
                        .foregroundStyle(block.state == "current" ? Theme.Color.ok : Theme.Color.warn)
                }
                .font(Theme.mono(12)).frame(minHeight: 24)
            }
            Text(verbatim: "Секреты в инструкции не попадают — только имена переменных.").font(Theme.ui(11.5)).foregroundStyle(Theme.Color.textMuted)
        }
    }

    /// The file is in the tooltip: with it the two columns do not fit the card's width.
    private func blockText(_ tool: SetupStatus.Tool, _ home: AgentHome) -> Text {
        guard let state = tool.instructions, let file = home.instructions(tool.tool) else { return Text(verbatim: "—") }
        let (label, color): (String, Color) = switch state {
        case "current": ("записан · " + shortDate(modified(file.path)), Theme.Color.ok)
        case "absent": ("нет", Theme.Color.textMuted)
        default: ("устарел · есть новая версия", Theme.Color.warn)
        }
        return Text(verbatim: label).foregroundStyle(color)
    }

    // MARK: Environment

    private func environment(_ status: SetupStatus?) -> some View {
        let setup = registry.setup
        let runtime = SetupModel.runtime
        let home = registry.registry.home
        let ready = runtime.version != nil && status?.commandInstalled == true
        return card("Окружение") {
            Text(verbatim: ready ? "всё на месте" : "не всё на месте").font(Theme.mono(10.5)).foregroundStyle(ready ? Theme.Color.ok : Theme.Color.warn)
        } content: {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    label("python")
                    Text(verbatim: runtime.version.map { [$0, tilde(PythonRuntime.directory.path), "установлено " + shortDate(runtime.date)].joined(separator: " · ") }
                         ?? "не установлено · " + tilde(PythonRuntime.directory.path))
                        .foregroundStyle(runtime.version == nil ? Theme.Color.warn : Theme.Color.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { Task { await setup.ensureRuntime() } } label: { Text(verbatim: setup.runtimeBusy ? "Обновляется…" : "Обновить") }
                        .disabled(setup.runtimeBusy)
                        .help(Text(verbatim: "Переписывает файлы окружения и запускает uv sync, если зависимости изменились"))
                }
                GridRow {
                    label("cli")
                    Text(verbatim: tilde(status?.command ?? "") + (status?.commandInstalled == true ? " · есть ✓" : " · не установлен"))
                        .foregroundStyle(status?.commandInstalled == false ? Theme.Color.warn : Theme.Color.text)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(status?.command ?? "", forType: .string)
                    } label: { Text(verbatim: "Скопировать путь") }
                }
                GridRow {
                    label("папка")
                    Text(verbatim: tilde(home.path) + " · local.yaml, secrets.json, runtime")
                    Button { NSWorkspace.shared.open(home) } label: { Text(verbatim: "Открыть ~/.practices в Finder") }
                }
            }
            .font(Theme.mono(12)).lineLimit(1).truncationMode(.middle)
            .buttonStyle(CompactButtonStyle(height: 24, fontSize: 12))
        }
    }

    private func label(_ s: String) -> some View {
        Text(verbatim: s).font(Theme.mono(11)).foregroundStyle(Theme.Color.textMuted).frame(width: 90, alignment: .leading)
    }

    // MARK: Card

    /// SectionCard with something on the right of its title.
    private func card<T: View, C: View>(_ title: String, @ViewBuilder trailing: () -> T, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) { SectionTitle(title); Spacer(); trailing() }
            content()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.cardBg, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.Color.borderCard))
    }

    private func card<C: View>(_ title: String, note: String, @ViewBuilder content: () -> C) -> some View {
        card(title, trailing: { Text(verbatim: note).font(Theme.mono(10.5)).foregroundStyle(Theme.Color.textMuted).lineLimit(1).truncationMode(.middle) }, content: content)
    }
}
