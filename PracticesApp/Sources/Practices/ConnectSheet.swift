import SwiftUI
import AppKit
import PracticesCore

/// Writes a service's values into a project's env file, once: which file, which environment,
/// which keys under which names. Nothing remembers the file afterwards (DECISIONS 18).
/// `design/ConnectSheet.dc.html`: values are never shown, only names and each line's state.
struct ConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RegistryModel.self) private var registry
    let service: Service

    @State private var project: URL?
    @State private var file = ".env"
    @State private var existingFiles: [String] = []
    @State private var env = ""
    @State private var rows: [Row] = []
    @State private var plan: [EnvFiles.Line] = []
    @State private var error: String?
    @State private var writing = false

    struct Row: Identifiable {
        let key: String
        var include: Bool
        var variable: String
        var id: String { key }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                (Text(verbatim: "Подключить ") + Text(verbatim: service.id).font(Theme.mono(15, .semibold))
                    .foregroundColor(ServiceClass(for: service).color) + Text(verbatim: " к проекту"))
                    .font(Theme.ui(15, .semibold)).foregroundStyle(Theme.Color.text)
                Text(verbatim: "значения попадут в env-файл проекта под именами, которые ждёт его код")
                    .font(Theme.ui(12)).foregroundStyle(Theme.Color.textMuted)
            }
            HStack(spacing: 10) {
                Text(verbatim: project.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Папка не выбрана")
                    .font(Theme.mono(12)).foregroundStyle(project == nil ? Theme.Color.textMuted : Theme.Color.text)
                    .lineLimit(1).truncationMode(.head).frame(maxWidth: .infinity, alignment: .leading)
                if let id = projectID { Chip(id, color: registry.zoneColor(of: id)) }
                Button { pickFolder() } label: { Text(verbatim: "Выбрать папку…") }.buttonStyle(ToolbarButtonStyle())
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    label("Файл")
                    field(".env", text: $file).frame(height: 28)
                    Menu {
                        ForEach(existingFiles, id: \.self) { f in Button { file = f } label: { Text(verbatim: f) } }
                    } label: { Text(verbatim: "Существующие ▾") }
                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(ToolbarButtonStyle()).fixedSize()
                    .disabled(existingFiles.isEmpty)
                }
                GridRow {
                    label("Окружение")
                    envSegments.gridCellColumns(2)
                }
            }
            Theme.Color.border.frame(height: 1)
            VStack(alignment: .leading, spacing: 2) {
                tableRow { Text(verbatim: "") } key: { header("ключ сервиса") } variable: { header("переменная в проекте") } state: { header("в файле") }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach($rows) { $row in
                            tableRow {
                                Toggle("", isOn: $row.include).labelsHidden().toggleStyle(.checkbox)
                            } key: {
                                Text(verbatim: row.key).font(Theme.mono(11.5))
                                    .foregroundStyle(row.include ? Theme.Color.textSecondary : Theme.Color.textGutter)
                            } variable: {
                                field(row.key, text: $row.variable).frame(height: 26).disabled(!row.include)
                            } state: {
                                stateText(for: row)
                            }
                            .frame(height: 30)
                        }
                    }
                }
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(verbatim: error).font(Theme.mono(11)).foregroundStyle(Theme.Color.error).textSelection(.enabled) }
            HStack(spacing: 10) {
                (Text(verbatim: "Остальные строки файла не трогаются. В файл под git секреты не запишутся — запись остановится; держите его в ")
                    + Text(verbatim: ".gitignore").font(Theme.mono(11)) + Text(verbatim: "."))
                    .font(Theme.ui(11)).foregroundStyle(Theme.Color.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { dismiss() } label: { Text(verbatim: "Отмена") }
                    .buttonStyle(ToolbarButtonStyle()).keyboardShortcut(.cancelAction)
                Button { write() } label: { Text(verbatim: "Записать " + ru(writeCount, "строку", "строки", "строк")) }
                    .buttonStyle(ToolbarButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    .disabled(project == nil || file.isEmpty || writeCount == 0 || writing)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 640)
        .background(Theme.Color.cardBg)
        .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12).strokeBorder(Theme.Color.borderButton))
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
        .presentationBackground(Theme.Color.cardBg)
        .onAppear {
            env = service.defaultEnv
            rows = service.keys.map { Row(key: $0.name, include: true, variable: $0.name) }
        }
        .onChange(of: env) { refreshPlan() }
        .onChange(of: file) { refreshPlan() }
        .onChange(of: rows.map { "\($0.include)\($0.variable)" }) { refreshPlan() }
    }

    private var writeCount: Int { rows.filter(\.include).count }

    /// The project whose repository's clone holds the chosen folder.
    private var projectID: String? {
        guard let path = project?.standardizedFileURL.path,
              let repo = registry.clones.first(where: { path == $0.value || path.hasPrefix($0.value + "/") })?.key else { return nil }
        return registry.projects.first { $0.repos.contains { $0.repo == repo } }?.id
    }

    private func label(_ text: String) -> some View {
        Text(verbatim: text).font(Theme.ui(13)).foregroundStyle(Theme.Color.textSecondary).frame(width: 90, alignment: .leading)
    }

    private func header(_ text: String) -> some View {
        Text(verbatim: text).textCase(.uppercase).font(Theme.ui(10.5, .semibold)).tracking(0.42).foregroundStyle(Theme.Color.textMuted)
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(text: text, prompt: Text(verbatim: prompt).foregroundColor(Theme.Color.textDisabled)) { Text(verbatim: prompt) }
            .textFieldStyle(.plain).font(Theme.mono(12)).foregroundStyle(Theme.Color.text)
            .padding(.horizontal, 8).frame(maxHeight: .infinity)
            .background(Theme.Color.windowBg, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Color.borderButton))
    }

    /// Columns 20 / 170 / rest / 150, as the design's table.
    private func tableRow<A: View, B: View, C: View, D: View>(@ViewBuilder _ check: () -> A, @ViewBuilder key: () -> B,
                                                              @ViewBuilder variable: () -> C, @ViewBuilder state: () -> D) -> some View {
        HStack(spacing: 10) {
            check().frame(width: 20, alignment: .leading)
            key().lineLimit(1).frame(width: 170, alignment: .leading)
            variable().frame(maxWidth: .infinity, alignment: .leading)
            state().lineLimit(1).frame(width: 150, alignment: .leading)
        }
    }

    /// The design's segment: accent on the chosen environment.
    private var envSegments: some View {
        HStack(spacing: 0) {
            ForEach(service.envs, id: \.self) { e in
                Button { env = e } label: {
                    Text(verbatim: e).font(Theme.ui(12)).foregroundStyle(env == e ? .white : Theme.Color.text)
                        .padding(.horizontal, 12).padding(.vertical, 2)
                        .background(env == e ? Theme.Color.accent : .clear, in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.Color.buttonBg, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Color.borderButton))
        .fixedSize()
    }

    private var managed: ManagedFile {
        let included = rows.filter(\.include)
        let aliases = Dictionary(included.filter { $0.variable != $0.key && !$0.variable.isEmpty }.map { ($0.variable, $0.key) },
                                 uniquingKeysWith: { a, _ in a })
        return ManagedFile(path: file, services: [ServiceRef(service: service.id, env: env)], env: aliases,
                           only: included.count == rows.count ? nil : included.map(\.key))
    }

    private func refreshPlan() {
        guard let project else { plan = []; return }
        plan = (try? EnvFiles.plan(managed, project: project)) ?? []
    }

    @ViewBuilder
    private func stateText(for row: Row) -> some View {
        if row.include, let line = plan.first(where: { $0.key == row.key }) {
            let (text, color): (String, Color) = switch line.state {
            case .same: ("без изменений", Theme.Color.textMuted)
            case .changed: ("изменится", Theme.Color.warn)
            case .new: ("добавится", Theme.Color.ok)
            case .missingValue: ("нет значения в реестре", Theme.Color.error)
            }
            Text(verbatim: text).font(Theme.mono(11)).foregroundStyle(color)
        } else {
            Text(verbatim: "")
        }
    }

    private func choose(_ dir: URL) {
        project = dir
        existingFiles = Doctor.collect(root: dir.path).env.filter { !$0.contains("/.claude/") }
            .map { $0.hasPrefix(dir.path + "/") ? String($0.dropFirst(dir.path.count + 1)) : $0 }
        refreshPlan()
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Projects")
        if panel.runModal() == .OK, let url = panel.url { choose(url) }
    }

    private func write() {
        guard let project else { return }
        writing = true
        error = nil
        let file = managed
        Task {
            do {
                try await EnvFiles.write(file, project: project)
                dismiss()
            } catch {
                self.error = String(describing: error)
            }
            writing = false
        }
    }
}
