import SwiftUI
import AppKit
import PracticesCore

/// A practice or a chain (`design/Practice.dc.html`): the code with its gutter, parameters from
/// `run()`'s signature, the run's status and result or a chain's steps; on the right the
/// versions with their medians, the fields of the result, the copies and the agent's commands.
struct PracticeView: View {
    @State var model: PracticeModel
    @Environment(RegistryModel.self) private var registry
    @State private var editorHeight: CGFloat = 318
    @State private var dragStart: CGFloat?
    @State private var showTraceback = false
    @FocusState private var focusedParam: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                strip
                CodeEditor(text: $model.code).frame(height: editorHeight)
                splitHandle
                VStack(spacing: 0) {
                    paramRow
                    statusRow
                    output
                        .padding(.horizontal, 12).padding(.bottom, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity)
            Theme.Color.border.frame(width: 1)
            inspector
        }
        .navigationTitle(model.practice.ref)
        .toolbarLeading {
            HStack(spacing: 6) {
                Breadcrumb(crumbs: crumbs, title: model.practice.name)
                versionChip
            }
        }
        .toolbarTrailing {
            Button { Task { await model.save() } } label: {
                HStack(spacing: 6) { Text(verbatim: "Сохранить версию"); Text(verbatim: "⌘S").font(Theme.mono(10.5)) }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!model.dirty)
            if model.running {
                Button { model.stop() } label: { runLabel("stop.fill", "Остановить", "⌘.") }
                    .buttonStyle(ToolbarButtonStyle(prominent: true))
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button { model.run() } label: { runLabel("play.fill", "Запустить", "⌘↩") }
                    .buttonStyle(ToolbarButtonStyle(prominent: true))
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    // MARK: Toolbar

    /// `space / project… / service` — the project in its zone colour, the service in its class colour.
    private var crumbs: [Crumb] {
        let service = model.practice.service.flatMap(registry.service)
        let project = service?.project ?? registry.chains.first { $0.value.contains(model.practice) }?.key
        let space = service?.space ?? project.flatMap(registry.project)?.space
        var out: [Crumb] = []
        if let space { out.append(Crumb(label: space) { registry.selection = .space(space) }) }
        for p in project.map(registry.path(of:)) ?? [] {
            out.append(Crumb(label: p.id, color: registry.zoneColor(of: p.id)) { registry.selection = .project(p.id) })
        }
        if let service {
            out.append(Crumb(label: service.id, color: ServiceClass(for: service).color) { registry.selection = .service(service.id) })
        }
        return out
    }

    /// «v3» grey badge; «черновик» in warn while the code differs from the saved version.
    @ViewBuilder private var versionChip: some View {
        if let label = model.dirty ? "черновик" : model.versions.last.map({ "v\($0.number)" }) {
            Text(verbatim: label).font(Theme.mono(10.5))
                .foregroundStyle(model.dirty ? Theme.Color.warn : Theme.Color.textChip)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(model.dirty ? Theme.Color.warn.opacity(0.16) : Color(hex: 0x9A9AA3, alpha: 0.16),
                            in: RoundedRectangle(cornerRadius: 4))
                .fixedSize()
        }
    }

    private func runLabel(_ glyph: String, _ title: String, _ shortcut: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: glyph).font(.system(size: 9))
            Text(verbatim: title)
            Text(verbatim: shortcut).font(Theme.mono(10.5)).opacity(0.85)
        }
    }

    // MARK: Editor

    /// 34 high: the docstring's first line; the file, its libraries and the env names it reads.
    private var strip: some View {
        HStack(spacing: 10) {
            Text(verbatim: model.signature?.doc?.components(separatedBy: "\n").first ?? "")
                .font(Theme.ui(12)).foregroundStyle(Theme.Color.textSecondary).lineLimit(1)
            Spacer(minLength: 0)
            Text(verbatim: fileSummary).font(Theme.mono(11)).foregroundStyle(Theme.Color.textMuted)
                .lineLimit(1).truncationMode(.head)
        }
        .padding(.horizontal, 12).frame(height: 34)
        .overlay(alignment: .bottom) { Theme.Color.border.frame(height: 1) }
    }

    private var fileSummary: String {
        let url = model.store.url(of: model.practice)
        var parts = [url.map { $0.deletingLastPathComponent().lastPathComponent + "/" + $0.lastPathComponent } ?? model.practice.name + ".py"]
        let libs = CodeFacts.libraries(in: model.code)
        if !libs.isEmpty { parts.append(libs.joined(separator: ", ")) }
        if let env = CodeFacts.envLabel(in: model.code) { parts.append("читает " + env) }
        return parts.joined(separator: " · ")
    }

    /// The 6pt split between the editor and the run: drag to give the code more room.
    private var splitHandle: some View {
        Theme.Color.toolbarBg
            .frame(height: 6)
            .overlay(alignment: .top) { Theme.Color.border.frame(height: 1) }
            .overlay(alignment: .bottom) { Theme.Color.border.frame(height: 1) }
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { drag in
                    let start = dragStart ?? editorHeight
                    dragStart = start
                    editorHeight = min(max(120, start + drag.translation.height), 900)
                }
                .onEnded { _ in dragStart = nil })
    }

    // MARK: Parameters

    private var paramRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                if let signature = model.signature, !signature.ok {
                    Text(verbatim: "⚠ " + (signature.error ?? "")).font(Theme.mono(11)).foregroundStyle(Theme.Color.warn).lineLimit(1)
                } else {
                    ForEach(model.signature?.params ?? [], id: \.name) { param in
                        HStack(spacing: 6) {
                            Text(verbatim: param.name).font(Theme.mono(11)).foregroundStyle(Theme.Color.textMuted)
                            TextField(text: Binding(get: { model.params[param.name] ?? "" }, set: { model.params[param.name] = $0 }),
                                      prompt: Text(verbatim: placeholder(param)).foregroundColor(Theme.Color.textDisabled)) {
                                Text(verbatim: param.name)
                            }
                            .textFieldStyle(.plain)
                            .font(Theme.mono(12)).foregroundStyle(Theme.Color.text)
                            .padding(.horizontal, 8).frame(width: 240, height: 24)
                            .background(Theme.Color.windowBg, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.Color.border))
                            .focused($focusedParam, equals: param.name)
                            .onSubmit { model.run() }
                        }
                    }
                }
                runHint
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .overlay(alignment: .bottom) { Theme.Color.border.frame(height: 1) }
    }

    private func placeholder(_ param: PracticeSignature.Param) -> String {
        [param.annotation, param.default.map { "= " + $0 }].compactMap { $0 }.joined(separator: " ")
    }

    /// The services the run takes keys from; each is a menu of its environments when it has several.
    private var runServices: [String] { model.store.services(for: model.practice) }

    private func env(of id: String) -> String { model.envs[id] ?? registry.service(id)?.defaultEnv ?? "prod" }

    private var runHint: some View {
        HStack(spacing: 4) {
            Text(verbatim: runServices.isEmpty ? "⌘↩ запускает" : "⌘↩ запускает с ключами")
            ForEach(runServices, id: \.self) { id in
                let envs = registry.service(id)?.envs ?? []
                if envs.count > 1 {
                    Menu {
                        ForEach(envs, id: \.self) { env in Button { model.envs[id] = env } label: { Text(verbatim: env) } }
                    } label: {
                        Text(verbatim: "\(id)@\(env(of: id))").foregroundStyle(Theme.Color.link)
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                } else {
                    Text(verbatim: "\(id)@\(env(of: id))")
                }
            }
        }
        .font(Theme.ui(11)).foregroundStyle(Theme.Color.textMuted)
        .fixedSize()
    }

    // MARK: Status and output

    @ViewBuilder private var statusRow: some View {
        if model.running || model.result != nil || model.failure != nil {
            HStack(spacing: 12) {
                if model.running {
                    Text(verbatim: "● выполняется").foregroundStyle(Theme.Color.textSecondary)
                } else if let r = model.result {
                    Text(verbatim: r.ok ? "● готово" : "● ошибка").foregroundStyle(r.ok ? Theme.Color.ok : Theme.Color.error)
                    Text(verbatim: metrics(ms: r.ms, rows: r.total, bytes: r.bytes)).foregroundStyle(Theme.Color.textSecondary)
                    if !r.secretsUpdated.isEmpty {
                        Text(verbatim: "обновлены ключи " + r.secretsUpdated.joined(separator: ", ")).foregroundStyle(Theme.Color.link)
                    }
                } else {
                    Text(verbatim: "● ошибка").foregroundStyle(Theme.Color.error)
                }
                Spacer(minLength: 0)
                Text(verbatim: envSummary(model.result?.envs ?? Dictionary(uniqueKeysWithValues: runServices.map { ($0, env(of: $0)) })))
                    .foregroundStyle(Theme.Color.textMuted).lineLimit(1)
            }
            .font(Theme.mono(11))
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    /// `service@env · condition ✓/✗` from the last check of the service's conditions.
    private func envSummary(_ envs: [String: String]) -> String {
        envs.sorted { $0.key < $1.key }.map { id, env in
            let conditions = (registry.service(id)?.conditionIDs ?? []).map { c in
                let check = registry.checks[id]?.first { $0.env == env && $0.endpoint == "requires:\(c)" }
                return c + (check.map { $0.ok ? " ✓" : " ✗" } ?? "")
            }
            return (["\(id)@\(env)"] + conditions).joined(separator: " · ")
        }
        .joined(separator: "  ")
    }

    @ViewBuilder private var output: some View {
        if let result = model.result {
            VStack(alignment: .leading, spacing: 0) {
                if !result.steps.isEmpty { steps(result) }
                if let i = model.selectedStep, i < result.steps.count {
                    stepOutput(result.steps[i])
                } else if result.ok {
                    ResultView(shape: result.shape, columns: result.columns ?? [], rows: result.rows ?? [],
                               tree: result.tree, text: result.text, stdout: result.stdout, schema: result.schema ?? [],
                               empty: emptyResult(result))
                } else {
                    failure(result)
                }
            }
        } else if let failure = model.failure {
            failureState(title: "Не выполнилась", error: failure, conditions: [], full: failure)
        } else if model.running {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(verbatim: "Ещё не запускалась. ⌘↩ запускает со значениями её сервисов.")
                .font(Theme.ui(12)).foregroundStyle(Theme.Color.textMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func steps(_ result: PracticeResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(result.steps.enumerated()), id: \.offset) { i, step in
                Button { model.selectedStep = model.selectedStep == i ? nil : i } label: {
                    HStack(spacing: 10) {
                        Text(verbatim: "\(i + 1)").font(Theme.mono(10.5)).monospacedDigit()
                            .foregroundStyle(step.ok ? Theme.Color.ok : Theme.Color.error)
                            .frame(width: 18, height: 18)
                            .background((step.ok ? Theme.Color.ok : Theme.Color.error).opacity(0.16), in: Circle())
                        Text(verbatim: step.ref).font(Theme.mono(12)).foregroundStyle(Theme.Color.text)
                        Spacer()
                        Text(verbatim: step.ok ? metrics(ms: step.ms, rows: step.total, bytes: nil) : (step.error ?? ""))
                            .font(Theme.mono(11)).foregroundStyle(step.ok ? Theme.Color.textSecondary : Theme.Color.error).lineLimit(1)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(model.selectedStep == i ? Theme.Color.accentSelection : Theme.Color.cardBg, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(verbatim: model.selectedStep == nil ? "Щёлкните шаг, чтобы увидеть его вывод." : "Вывод шага. Щёлкните его ещё раз — итоговый результат.")
                .font(Theme.ui(11)).foregroundStyle(Theme.Color.textMuted)
        }
        .padding(.bottom, 6)
    }

    private func stepOutput(_ step: PracticeResult.Step) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let input = step.input {
                Text(verbatim: "input: \(input)").font(Theme.mono(11)).foregroundStyle(Theme.Color.textSecondary).lineLimit(2)
                    .padding(.bottom, 4)
            }
            if step.ok {
                ResultView(shape: step.shape, columns: step.columns ?? [], rows: step.rows ?? [],
                           tree: step.tree, text: step.text, stdout: "", schema: step.schema ?? [])
            } else {
                ResultText(text: step.error ?? "", color: Theme.Color.error)
            }
        }
    }

    private func failure(_ result: PracticeResult) -> some View {
        let trace = [result.traceback ?? "", result.stderr, result.stdout].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return failureState(title: "Не выполнилась · \(result.ms) ms", error: result.traceback ?? result.error ?? "",
                            conditions: result.conditions ?? [], full: trace.isEmpty ? (result.error ?? "") : trace)
    }

    /// The error state: the traceback's last line, then the declared conditions of its services
    /// (a bare 401 does not say "log in to System"), the one a check saw fail marked as unmet.
    private func failureState(title: String, error: String, conditions: [Condition], full: String) -> some View {
        let lastLine = error.split(whereSeparator: \.isNewline).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? error
        let unmet = conditions.filter { c in
            runServices.contains { id in registry.checks[id]?.first { $0.env == env(of: id) && $0.endpoint == "requires:\(c.id)" }?.ok == false }
        }
        let lines = conditions.map { c in
            "⚑ " + c.name + (unmet.contains(c) ? " — условие не выполнено" : c.hint.map { " — " + $0 } ?? "")
        }
        let text = unmet.first.map { "Условия сервиса проверяются первыми: не выполнено «\($0.name)»." }
            ?? "Последняя строка трейсбека — здесь, полный — по кнопке."
        return VStack(spacing: 8) {
            EmptyState(glyph: "✕", tint: Theme.Color.error, title: title, text: text,
                       code: ([lastLine] + lines).joined(separator: "\n"), alert: true) {
                StateButton("Повторить", prominent: true) { model.run() }
                StateButton(showTraceback ? "Скрыть трейсбек" : "Полный трейсбек") { showTraceback.toggle() }
            }
            if showTraceback { ResultText(text: full, color: Theme.Color.textSecondary) }
        }
        .padding(.top, 6)
    }

    /// The empty result: what was asked — parameters, version, environments — and where to look.
    private func emptyResult(_ result: PracticeResult) -> ResultView.Empty {
        let params = (model.signature?.params ?? []).map(\.name)
        let asked = params.compactMap { name in model.params[name].flatMap { $0.isEmpty ? nil : "\(name)=\($0)" } }.joined(separator: "  ")
        let version = model.dirty ? "черновик" : model.versions.last.map { "v\($0.number)" }
        let envs = result.envs.sorted { $0.key < $1.key }.map(\.value).joined(separator: ", ")
        let code = [asked, version ?? "", envs].filter { !$0.isEmpty }.joined(separator: "  ·  ")
        let hint = params.isEmpty ? "." : " — у \(model.practice.name) это " + params.joined(separator: ", ") + "."
        return ResultView.Empty(ms: result.ms, text: "Запрос выполнен, но ничего не вернул. Проверьте параметры" + hint, code: code) {
            if let first = params.first { focusedParam = first } else { model.run() }
        }
    }

    private func metrics(ms: Int, rows: Int?, bytes: Int?) -> String {
        var parts = [duration(ms)]
        if let rows { parts.append("\(rows) " + (rows == 1 ? "row" : "rows")) }
        if let bytes { parts.append(bytes >= 1024 ? "\(bytes / 1024) KB" : "\(bytes) B") }
        return parts.joined(separator: " · ")
    }

    private func duration(_ ms: Int) -> String { ms >= 1000 ? String(format: "%.1f s", Double(ms) / 1000) : "\(ms) ms" }

    // MARK: Inspector

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    versionsSection
                    fieldsSection
                    copiesSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            agentBlock
        }
        .font(Theme.ui(12))
        .padding(.horizontal, 10).padding(.vertical, 12)
        .frame(width: 270)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.Color.toolbarBg)
    }

    private func inspectorTitle(_ text: String) -> some View {
        SectionTitle(text).padding(.leading, 6).padding(.bottom, 2)
    }

    private struct VersionRow {
        let name: String
        let date: String?
        let median: String
        let color: Color
        let bar: CGFloat
        let runs: String
    }

    /// Saved versions newest first (and the draft when it has runs): the best median in ok, the
    /// slowest in warn, the bar proportional to the slowest.
    private var versionRows: [VersionRow] {
        let timings = Dictionary(model.timings.map { ($0.version, $0) }, uniquingKeysWith: { a, _ in a })
        let medians = model.timings.map(\.median).filter { $0 > 0 }
        let best = medians.min(), slowest = medians.max() ?? 1
        var numbers: [Int?] = model.versions.map(\.number).sorted(by: >)
        if timings[Int?.none] != nil { numbers.insert(nil, at: 0) }
        return numbers.map { n in
            let t = timings[n]
            let median = t?.median ?? 0
            let color = median == 0 ? Theme.Color.textSecondary : median == best ? Theme.Color.ok
                : median == slowest ? Theme.Color.warn : Theme.Color.textSecondary
            return VersionRow(
                name: n.map { "v\($0)" } ?? "черновик",
                date: model.versions.first { $0.number == n }?.date
                    .formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "ru_RU"))),
                median: median == 0 ? "—" : duration(median),
                color: color,
                bar: median == 0 ? 0 : CGFloat(median) / CGFloat(slowest),
                runs: t.map { ru($0.count, "запуск", "запуска", "запусков") + ($0.failed > 0 ? ", \($0.failed) с ошибкой" : "") } ?? "нет запусков")
        }
    }

    private var versionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            inspectorTitle("Версии · медиана")
            let rows = versionRows
            ForEach(rows.indices, id: \.self) { i in
                let v = rows[i]
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(verbatim: v.name).font(Theme.mono(12)).foregroundStyle(Theme.Color.text)
                        if let date = v.date {
                            Text(verbatim: date).font(Theme.mono(10.5)).foregroundStyle(Theme.Color.textMuted).padding(.leading, 8)
                        }
                        Spacer(minLength: 8)
                        Text(verbatim: v.median).font(Theme.mono(11)).monospacedDigit().foregroundStyle(v.color)
                    }
                    if v.bar > 0 {
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 2).fill(v.color).opacity(0.7).frame(width: geo.size.width * v.bar)
                        }
                        .frame(height: 4)
                    }
                    Text(verbatim: v.runs).font(Theme.ui(10)).foregroundStyle(Theme.Color.textMuted)
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
            }
            if rows.isEmpty { quiet("Версий ещё нет") }
        }
    }

    /// The last result's schema, else the last successful run's (fields.yaml is per service, not per practice).
    private var fields: [PracticeResult.Field] {
        if let schema = model.result?.schema, !schema.isEmpty { return schema }
        guard let json = model.runs.first(where: { $0.ok && $0.schema != nil })?.schema else { return [] }
        return (try? JSONDecoder().decode([PracticeResult.Field].self, from: Data(json.utf8))) ?? []
    }

    private var fieldsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            inspectorTitle("Поля в результате")
            let fields = self.fields
            ForEach(fields, id: \.path) { f in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: f.path).font(Theme.mono(11)).foregroundStyle(Theme.Color.text).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(verbatim: f.type).font(Theme.mono(10)).foregroundStyle(ResultTable.typeColor)
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
            }
            if fields.isEmpty { quiet("Появятся после первого запуска") }
        }
    }

    @ViewBuilder private var copiesSection: some View {
        let copies = (registry.copies ?? []).filter { $0.ref == model.practice.ref }
        if !copies.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                inspectorTitle("Копии · \(copies.count)")
                ForEach(copies, id: \.self) { copy in
                    let state = copyState(copy)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: shortPath(copy.path)).foregroundStyle(Theme.Color.text).lineLimit(1).truncationMode(.middle)
                        Text(verbatim: state.0).foregroundStyle(state.1)
                    }
                    .font(Theme.mono(11))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .help(copy.path + ":\(copy.line)")
                }
            }
        }
    }

    private func copyState(_ copy: PracticeCopy) -> (String, Color) {
        let v = copy.version.map { "v\($0)" } ?? "v?"
        switch copy.state {
        case .current: return ("\(v) · актуальна", Theme.Color.ok)
        case .outdated: return ("\(v) → v\(copy.latest)", Theme.Color.warn)
        case .modified: return ("изменена", Theme.Color.link)
        case .unknown: return ("\(v) · нет в реестре", Theme.Color.textMuted)
        }
    }

    private func shortPath(_ path: String) -> String {
        let short = (path as NSString).abbreviatingWithTildeInPath
        return short.hasPrefix("~/Projects/") ? String(short.dropFirst("~/Projects/".count)) : short
    }

    /// What an agent types to take this practice or try it: a click copies the line.
    private var agentBlock: some View {
        let ref = model.practice.ref
        let args = (model.signature?.params ?? []).map { " \($0.name)=…" }.joined()
        return VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "скопировать для агента").foregroundStyle(Theme.Color.textMuted)
            copyLine("get_practice \(ref)")
            copyLine("practicesctl try \(ref)" + args)
        }
        .font(Theme.mono(10.5)).foregroundStyle(Theme.Color.textSecondary)
        .padding(.horizontal, 6).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.codeBg, in: RoundedRectangle(cornerRadius: 6))
    }

    private func copyLine(_ text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Text(verbatim: text).lineLimit(1).truncationMode(.tail).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)
    }

    private func quiet(_ text: String) -> some View {
        Text(verbatim: text).font(Theme.ui(11)).foregroundStyle(Theme.Color.textMuted).padding(.horizontal, 6)
    }
}

/// What the strip says about the code: imported libraries and the env names it reads.
enum CodeFacts {
    /// shortcut: a hand list of common stdlib modules, not `sys.stdlib_module_names`; extend when one shows up.
    static let stdlib: Set<String> = ["os", "sys", "json", "re", "time", "datetime", "math", "typing", "collections",
                                      "itertools", "functools", "urllib", "base64", "hashlib", "hmac", "uuid", "decimal",
                                      "pathlib", "dataclasses", "ssl", "socket", "struct", "subprocess", "logging", "io",
                                      "csv", "random", "string", "zoneinfo", "contextlib", "enum", "asyncio", "http",
                                      "gzip", "zlib", "statistics", "operator", "textwrap", "tempfile", "shutil", "__future__"]
    static let importRegex = try! NSRegularExpression(pattern: #"^[ \t]*(?:import[ \t]+([\w., \t]+)|from[ \t]+(\w[\w.]*)[ \t]+import)"#,
                                                      options: .anchorsMatchLines)
    static let envRegex = try! NSRegularExpression(pattern: #"(?:\b(?:environ|env)(?:\[|\.get\()|getenv\()\s*['"]([A-Za-z_][A-Za-z0-9_]*)['"]"#)

    /// Top-level third-party modules in import order; the house `practices` package is not one.
    static func libraries(in code: String) -> [String] {
        let ns = code as NSString
        var out: [String] = []
        for m in importRegex.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            let names = m.range(at: 1).location != NSNotFound
                ? ns.substring(with: m.range(at: 1)).split(separator: ",").compactMap { $0.split(whereSeparator: \.isWhitespace).first }
                : [Substring(ns.substring(with: m.range(at: 2)))]
            for name in names {
                let top = String(name.split(separator: ".").first ?? "")
                if !top.isEmpty, !stdlib.contains(top), top != "practices", !out.contains(top) { out.append(top) }
            }
        }
        return out
    }

    /// `XK_PG_*` — the common prefix of the names read, cut at an underscore; one name as is.
    static func envLabel(in code: String) -> String? {
        let ns = code as NSString
        var names: [String] = []
        for m in envRegex.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            if !names.contains(name) { names.append(name) }
        }
        guard let first = names.first else { return nil }
        if names.count == 1 { return first }
        let common = names.dropFirst().reduce(first) { a, b in String(zip(a, b).prefix { $0 == $1 }.map(\.0)) }
        guard let cut = common.lastIndex(of: "_") else { return nil }
        return String(common[...cut]) + "*"
    }
}
