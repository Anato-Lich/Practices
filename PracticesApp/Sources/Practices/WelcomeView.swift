import SwiftUI
import AppKit
import PracticesCore

/// «Начало» (`design/Welcome.dc.html`): the first run, three steps — where the clones are, your
/// own space (the catalogue is personal, DECISIONS 36), the agents. The parts of steps 1 and 2 are shared with «Настройка».
///
/// No live «настраивает агент» mode (`WelcomeAgent.dc.html`): the MCP process sends the app no
/// signal; the window re-reads `Setup.status` when it becomes active instead (MainWindow).
struct WelcomeView: View {
    @Environment(RegistryModel.self) private var registry
    @State private var unchecked: Set<AgentTool> = []
    @State private var scope: InstructionScope?

    var body: some View {
        let setup = registry.setup
        let status = setup.status
        let states = steps(status)
        let current = states.firstIndex { $0 != .done }
        VStack(alignment: .leading, spacing: 12) {
            StepCard(n: 1, title: "Где лежат клоны", text: "папки с вашими проектами; каталог ищет в них git-клоны",
                     state: states[0], current: current == 0) {
                Button { Task { await setup.addRoots(chooseFolders()) } } label: { Text(verbatim: "Добавить папку…") }
                    .buttonStyle(ToolbarButtonStyle())
            } content: {
                RootsList(status: status)
                if let status {
                    HStack(spacing: 12) {
                        let n = status.roots.reduce(0) { $0 + $1.clones }
                        Text(verbatim: "в " + ru(status.roots.count, "папке", "папках", "папках") + " " + ru(n, "клон", "клона", "клонов"))
                            .font(Theme.mono(11.5)).foregroundStyle(n > 0 ? Theme.Color.ok : Theme.Color.textMuted)
                        (Text(verbatim: "Не весь диск: только папки, где лежат проекты · ")
                         + Text(verbatim: "\(tilde(PracticesHome.url.path))/local.yaml → roots").font(Theme.mono(11.5)))
                            .font(Theme.ui(11.5)).foregroundStyle(Theme.Color.textMuted)
                    }
                }
            }
            StepCard(n: 2, title: "Своё пространство", text: "каталог личный: проекты, сервисы и практики, которые вы ведёте",
                     state: states[1], current: current == 1) {
                EmptyView()
            } content: {
                if states[1] == .done {
                    Text(verbatim: "есть: " + registry.spaces.map(\.name).joined(separator: ", ") + " · ещё одно — в «Настройке»")
                        .font(Theme.mono(11.5)).foregroundStyle(Theme.Color.textMuted)
                } else {
                    CreateSpaceRow(label: "Создать пространство")
                }
            }
            StepCard(n: 3, title: "Агенты", text: "MCP-сервер в найденных инструментах, блок инструкций — Claude Code и Codex",
                     state: states[2], current: current == 2) {
                let tools = (status?.tools ?? []).filter { $0.found && !unchecked.contains($0.tool) }.map(\.tool)
                let scope = scope ?? setup.scope ?? .global
                let installed = status?.commandInstalled == true
                if status != nil && !installed {
                    // Agents run ~/.practices/bin/practicesctl: it is copied out of the app first.
                    Button { Task { await setup.installCommand() } } label: { Text(verbatim: "Установить practicesctl") }
                        .buttonStyle(ToolbarButtonStyle(prominent: true))
                        .disabled(setup.busy.contains("command"))
                }
                Button { Task { await setup.setupAgents(tools, scope: scope) } } label: { Text(verbatim: "Настроить агентов") }
                    .buttonStyle(ToolbarButtonStyle(prominent: installed))
                    .disabled(!installed || tools.isEmpty || setup.busy.contains("agents") || scope == .projects && setup.projectClones == 0)
            } content: {
                ScopeSegments(scope: Binding(get: { scope ?? setup.scope ?? .global }, set: { scope = $0 }), clones: setup.projectClones)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(status?.tools ?? [], id: \.tool) { tool in agentRow(tool) }
                }
                let found = (status?.tools ?? []).filter(\.found).map(\.tool.title)
                Text(verbatim: (status?.commandInstalled == false ? "Сначала — practicesctl: команда, которую агенты запускают как MCP-сервер, копируется из приложения в " + tilde(status?.command ?? "") + ". " : "")
                     + (found.isEmpty ? "Ни одного инструмента не найдено." : "Найденные инструменты: " + found.joined(separator: ", ") + ".")
                     + " Блок помечен маркерами, повторный запуск обновляет только его. Секреты не попадают — только имена переменных.")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.Color.textMuted)
            }
            Spacer(minLength: 0)
            HStack(spacing: 14) {
                Button {
                    Task {
                        await registry.reload()
                        registry.selection = registry.spaces.first.map { .space($0.id) }
                        registry.welcomeShown = false
                    }
                } label: { Text(verbatim: "Открыть каталог").font(Theme.ui(13, .semibold)) }
                    .buttonStyle(CompactButtonStyle(prominent: true, height: 30))
                    .disabled(registry.spaces.isEmpty)
                Button { registry.welcomeShown = false } label: { Text(verbatim: "Настроить позже").font(Theme.ui(12.5)).foregroundStyle(Theme.Color.link) }
                    .buttonStyle(.plain)
                Spacer()
                Text(verbatim: "то же из терминала: practicesctl setup roots · space add · setup agents")
                    .font(Theme.mono(11)).foregroundStyle(Theme.Color.textMuted)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { if setup.status == nil { await setup.refresh() } }
        .toolbarLeading {
            HStack(spacing: 12) {
                Text(verbatim: "Начало").font(Theme.ui(15, .semibold)).foregroundStyle(Theme.Color.text)
                Text(verbatim: "первый запуск · всё личное хранится в \(tilde(PracticesHome.url.path)) и не попадает в git (решение 36)")
                    .font(Theme.mono(12)).foregroundStyle(Theme.Color.textSecondary).lineLimit(1)
            }
        }
    }

    private func steps(_ status: SetupStatus?) -> [StepState] {
        let setup = registry.setup
        let roots: StepState = setup.busy.contains("roots") ? .running
            : (status?.roots.contains { $0.clones > 0 } ?? false) ? .done : .todo
        let space: StepState = setup.busy.contains("create") ? .running : !registry.spaces.isEmpty ? .done : .todo
        let found = (status?.tools ?? []).filter(\.found)
        let agents: StepState = setup.busy.contains("agents") ? .running
            : !found.isEmpty && found.allSatisfy({ $0.mcp && (status?.scope == .projects || ($0.instructions ?? "current") == "current") }) ? .done : .todo
        return [roots, space, agents]
    }

    private func agentRow(_ tool: SetupStatus.Tool) -> some View {
        let home = AgentHome()
        // Cursor keeps its rules in its own settings: it gets the MCP server only.
        let global = (scope ?? registry.setup.scope ?? .global) == .global && home.instructions(tool.tool) != nil
        let where_ = [tilde(home.mcpConfig(tool.tool).path), global ? home.instructions(tool.tool).map { tilde($0.path) } : nil].compactMap { $0 }.joined(separator: " и ")
        let on = Binding(get: { tool.found && !unchecked.contains(tool.tool) },
                         set: { if $0 { unchecked.remove(tool.tool) } else { unchecked.insert(tool.tool) } })
        return HStack(spacing: 10) {
            Toggle(isOn: on) {
                if tool.found {
                    Text(verbatim: tool.tool.title + (global ? " — MCP-сервер и блок инструкций: " : " — MCP-сервер: ")) + Text(verbatim: where_).font(Theme.mono(12))
                } else {
                    Text(verbatim: tool.tool.title + " — на машине не найден")
                }
            }
            .toggleStyle(.checkbox).disabled(!tool.found)
            .lineLimit(1).truncationMode(.middle)
            .font(Theme.ui(12.5)).foregroundStyle(tool.found ? Theme.Color.text : Theme.Color.textDisabled)
            if tool.found { AgentState(tool: tool) }
        }
    }
}

// MARK: - Step card

enum StepState { case todo, running, done, failed }

/// The step's pill (tokens.md «Статус-пилюля шага»): 22 high, radius 11, mono 11, outline and text in the state's colour.
struct StepPill: View {
    let state: StepState
    var body: some View {
        let (glyph, label, color): (String, String, Color) = switch state {
        case .todo: ("○", "не сделано", Theme.Color.textMuted)
        case .running: ("◌", "выполняется", Theme.Color.accent)
        case .done: ("✓", "готово", Theme.Color.ok)
        case .failed: ("✕", "ошибка", Theme.Color.error)
        }
        HStack(spacing: 6) { Text(verbatim: glyph); Text(verbatim: label) }
            .font(Theme.mono(11)).foregroundStyle(color)
            .padding(.horizontal, 8).frame(height: 22)
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(color))
            .fixedSize()
    }
}

/// A step of «Начало»: the number in a 26 px circle (✓ when done), title and line, pill and
/// button on the right; the current step is outlined in accent.
struct StepCard<Trailing: View, Content: View>: View {
    let n: Int
    let title: String
    let text: String
    let state: StepState
    let current: Bool
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                let fill = state == .done ? Theme.Color.ok : current ? Theme.Color.accent : Theme.Color.buttonBg
                Text(verbatim: state == .done ? "✓" : String(n)).font(Theme.mono(12, .semibold))
                    .foregroundStyle(state == .done || current ? .white : Theme.Color.textMuted)
                    .frame(width: 26, height: 26)
                    .background(fill, in: Circle())
                    .overlay(Circle().strokeBorder(state == .done || current ? fill : Theme.Color.borderButton))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).font(Theme.ui(15, .semibold))
                    Text(verbatim: text).font(Theme.ui(12)).foregroundStyle(Theme.Color.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 10)
                StepPill(state: state)
                trailing()
            }
            VStack(alignment: .leading, spacing: 8) { content() }.padding(.leading, 38)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.cardBg, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(current ? Theme.Color.accent : Theme.Color.borderCard))
    }
}

// MARK: - Shared with «Настройка»

/// The roots from `local.yaml` with their clone counts.
struct RootsList: View {
    @Environment(RegistryModel.self) private var registry
    let status: SetupStatus?
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(status?.roots ?? [], id: \.path) { root in
                HStack(spacing: 10) {
                    Text(verbatim: tilde(root.path)).font(Theme.mono(12)).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: !root.exists ? "нет такой папки"
                         : ru(root.clones, "клон", "клона", "клонов") + (note.map { " · " + $0 } ?? ""))
                        .font(Theme.mono(11)).foregroundStyle(root.exists ? Theme.Color.textMuted : Theme.Color.warn).fixedSize()
                    Spacer()
                    RemoveButton { Task { await registry.setup.removeRoot(root.path) } }
                }
                .frame(height: 28)
            }
        }
    }
}

/// «Глобально / В проектах»: where the instruction block goes (the segment of ConnectSheet), with
/// the number of clones the second one writes into.
struct ScopeSegments: View {
    @Binding var scope: InstructionScope
    let clones: Int

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(InstructionScope.allCases, id: \.self) { s in
                    Button { scope = s } label: {
                        Text(verbatim: s == .global ? "Глобально" : "В проектах · " + ru(clones, "клон", "клона", "клонов"))
                            .font(Theme.ui(12)).foregroundStyle(scope == s ? .white : Theme.Color.text)
                            .padding(.horizontal, 12).padding(.vertical, 2)
                            .background(scope == s ? Theme.Color.accent : .clear, in: RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Theme.Color.buttonBg, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Color.borderButton))
            .fixedSize()
            Text(verbatim: scope == .global ? "~/.claude/CLAUDE.md, ~/.codex/AGENTS.md" : "CLAUDE.md и AGENTS.md в каждом клоне проектов каталога")
                .font(Theme.mono(11)).foregroundStyle(Theme.Color.textMuted).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// «✕» in a row: 22×22, muted.
struct RemoveButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(verbatim: "✕").font(Theme.ui(14)).foregroundStyle(Theme.Color.textMuted).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(Text(verbatim: "Убрать"))
    }
}

/// Name + id + «Создать»: a new empty space (`Registry.add(Space)`).
struct CreateSpaceRow: View {
    @Environment(RegistryModel.self) private var registry
    var label: String?
    @State private var name = ""
    @State private var id = ""

    var body: some View {
        HStack(spacing: 10) {
            if let label { Text(verbatim: label).font(Theme.ui(12)).foregroundStyle(Theme.Color.textMuted) }
            TextField(text: $name, prompt: Text(verbatim: "Название").foregroundStyle(Theme.Color.textDisabled)) { Text(verbatim: "Название") }
                .fieldStyle().frame(width: 200)
            TextField(text: $id, prompt: Text(verbatim: "id").foregroundStyle(Theme.Color.textDisabled)) { Text(verbatim: "id") }
                .fieldStyle().frame(width: 150)
            Button {
                let (id, name) = (id, name)
                Task { if await registry.setup.create(id: id, name: name) { self.id = ""; self.name = "" } }
            } label: { Text(verbatim: "Создать") }
                .buttonStyle(ToolbarButtonStyle())
                .disabled(!Registry.isValidID(id) || name.trimmingCharacters(in: .whitespaces).isEmpty || registry.setup.busy.contains("create"))
        }
    }
}

/// «записан · 7 ноя» / «устарел» / «не записан» for a found tool: MCP and the instruction block together.
struct AgentState: View {
    let tool: SetupStatus.Tool
    var body: some View {
        let file = AgentHome().instructions(tool.tool)
        let state = tool.instructions ?? "current"
        let (text, color): (String, Color) = !tool.mcp && (tool.instructions ?? "absent") == "absent" ? ("не записан", Theme.Color.textMuted)
            : state.hasPrefix("outdated") ? ("устарел · есть новая версия", Theme.Color.warn)
            : !tool.mcp || state == "absent" ? ("записан частично", Theme.Color.warn)
            : ("записан" + (file.flatMap { modified($0.path) }.map { " · " + shortDate($0) } ?? ""), Theme.Color.ok)
        Text(verbatim: text).font(Theme.mono(11.5)).foregroundStyle(color)
    }
}

extension View {
    /// Text field of the design: 28 high, mono 12, window background, button border.
    func fieldStyle() -> some View {
        textFieldStyle(.plain).font(Theme.mono(12)).foregroundStyle(Theme.Color.text)
            .padding(.horizontal, 8).frame(height: 28)
            .background(Theme.Color.windowBg, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Color.borderButton))
    }
}

/// Folders to add as roots: directories only, several at once.
@MainActor func chooseFolders() -> [URL] {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.prompt = "Добавить"
    panel.message = "Папки, где лежат клоны проектов"
    return panel.runModal() == .OK ? panel.urls : []
}
