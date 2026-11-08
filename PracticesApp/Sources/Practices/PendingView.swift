import SwiftUI
import PracticesCore

/// What agents wrote into the spaces and the user has not accepted (`design/Pending.dc.html`):
/// files by space on the left, the diff of the chosen one, and the commit that accepts it
/// (DECISIONS 19).
struct PendingView: View {
    @Environment(RegistryModel.self) private var registry
    @State private var selected: Pending?
    @State private var diff = ""
    @State private var discarding: Pending?

    var body: some View {
        Group {
            if registry.pending.isEmpty {
                EmptyState(glyph: "✓", tint: Theme.Color.ok, title: "Всё принято",
                           text: "Правок агентов нет. Новые появятся после update_practice или add_link и останутся здесь до вашего решения.",
                           code: registry.spaces.compactMap { s in
                               registry.spaceGit[s.id].map { "\(s.id): \($0.branch ?? "HEAD") · \($0.uncommitted == 0 ? "чисто" : "\($0.uncommitted) не закоммичено")" }
                           }.joined(separator: "   "))
                    .padding(20)
            } else {
                HStack(spacing: 0) {
                    list
                    Theme.Color.border.frame(width: 1)
                    detail
                }
            }
        }
        .toolbarLeading { title }
        .toolbarTrailing {
            Button { Task { await registry.refreshPending() } } label: {
                Label { Text(verbatim: "Обновить") } icon: { Image(systemName: "arrow.clockwise") }
            }
            Button { Task { await registry.accept() } } label: { Text(verbatim: "Принять всё") }
                .disabled(registry.pending.isEmpty)
        }
        .task(id: registry.pending) {
            if let selected, registry.pending.contains(selected) { return }
            selected = registry.pending.first
        }
        .task(id: selected) {
            if let selected { diff = await registry.diff(of: selected) } else { diff = "" }
        }
        // A rejected draft is gone for good (nothing was committed), so one question first.
        .confirmationDialog(discarding.map { "Отклонить \(($0.path as NSString).lastPathComponent)?" } ?? "", isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }), titleVisibility: .visible, presenting: discarding) { change in
            Button(change.state == "new" ? "Удалить файл" : "Вернуть как было", role: .destructive) { Task { await registry.discard(change) } }
        } message: { change in
            Text(verbatim: change.state == "new" ? "Файл агента удалится; в истории каталога его нет." : "Правка агента отменится, файл вернётся к последнему принятому состоянию.")
        }
    }

    // MARK: Toolbar

    private var title: some View {
        let p = registry.pending
        let added = p.filter { $0.state == "new" }.count
        let modified = p.filter { $0.state == "modified" }.count
        let deleted = p.filter { $0.state == "deleted" }.count
        var line = Text(verbatim: ru(p.count, "файл", "файла", "файлов") + " · "
                        + ru(Set(p.map(\.space)).count, "пространство", "пространства", "пространств"))
        if added > 0 { line = line + Text(verbatim: " · ") + Text(verbatim: ru(added, "новый", "новых", "новых")).foregroundStyle(Theme.Color.ok) }
        if modified > 0 { line = line + Text(verbatim: " · ") + Text(verbatim: ru(modified, "изменён", "изменены", "изменены")).foregroundStyle(Theme.Color.warn) }
        if deleted > 0 { line = line + Text(verbatim: " · ") + Text(verbatim: ru(deleted, "удалён", "удалены", "удалены")).foregroundStyle(Theme.Color.error) }
        return HStack(spacing: 10) {
            Text(verbatim: "Ждут приёмки").font(Theme.ui(15, .semibold)).foregroundStyle(Theme.Color.text)
            line.font(Theme.mono(12)).foregroundStyle(Theme.Color.textSecondary).lineLimit(1)
        }
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(registry.spaces.filter { space in registry.pending.contains { $0.space == space.id } }) { space in
                    let changes = registry.pending.filter { $0.space == space.id }
                    SectionTitle("\(space.id) · \(changes.count)")
                        .padding(.horizontal, 8).padding(.top, 8)
                        .frame(maxWidth: .infinity, minHeight: 26, alignment: .bottomLeading)
                    ForEach(changes, id: \.self) { row($0) }
                }
            }
            .padding(8)
        }
        .scrollIndicators(.never)
        .frame(width: 360)
    }

    // A button, not a list selection: the file stays chosen while the window is not key.
    private func row(_ change: Pending) -> some View {
        let path = change.path as NSString
        let py = path.pathExtension == "py"
        let kind: ServiceClass = py ? .worker : .api
        return Button { selected = change } label: {
            HStack(spacing: 8) {
                Text(verbatim: py ? "py" : "yaml").font(Theme.mono(10)).foregroundStyle(kind.color)
                    .frame(width: 34).padding(.vertical, 1)
                    .background(kind.rgbBadgeBackground, in: RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: path.lastPathComponent).font(Theme.mono(12)).foregroundStyle(Theme.Color.text)
                    Text(verbatim: path.deletingLastPathComponent).font(Theme.mono(10.5)).foregroundStyle(Theme.Color.textMuted)
                }
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: change.stateLabel).font(Theme.mono(10.5)).foregroundStyle(change.stateColor)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(selected == change ? Theme.Color.accentSelection : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        let lines = DiffLine.parse(diff, new: selected?.state == "new")
        VStack(spacing: 0) {
            if let selected { header(selected, lines) }
            // An explicit width: `maxWidth: .infinity` in a two-way ScrollView is the viewport, which cut long lines.
            let content = 36 + 10 + 14 + 12 + CGFloat((lines.map(\.text.count).max() ?? 0) + 2) * Self.charWidth
            GeometryReader { geometry in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines.indices, id: \.self) { diffRow(lines[$0]) }
                    }
                    .frame(width: max(geometry.size.width, content), alignment: .leading)
                }
                .scrollIndicators(.visible, axes: .horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Color.codeBg)
        }
        .frame(maxWidth: .infinity)
    }

    private func header(_ change: Pending, _ lines: [DiffLine]) -> some View {
        let plus = lines.filter { $0.sign == "+" }.count, minus = lines.filter { $0.sign == "-" }.count
        let practice = change.practice
        let badge = switch change.state {
        case "new": "new · +\(plus)"
        case "deleted": "del · −\(minus)"
        default: "mod · +\(plus) −\(minus)"
        }
        let note = change.state == "new" && practice != nil
            ? "черновик агента" + (practice.flatMap { registry.lastRun(of: $0.ref) } == nil ? " · не запускалась" : "")
            : "ждёт приёмки"
        return HStack(spacing: 10) {
            if case let (id, rest)? = change.servicePath {
                Button { registry.selection = .service(id) } label: {
                    Text(verbatim: id).foregroundStyle(registry.service(id).map { ServiceClass(for: $0).color } ?? Theme.Color.link).lineLimit(1).fixedSize()
                }
                .buttonStyle(.plain)
                Text(verbatim: "/").foregroundStyle(Theme.Color.textMuted)
                Text(verbatim: rest).lineLimit(1).truncationMode(.head)
            } else {
                Text(verbatim: change.path).lineLimit(1).truncationMode(.head)
            }
            Text(verbatim: badge).font(Theme.mono(10.5)).foregroundStyle(change.stateColor)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(change.stateColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                .fixedSize()
            Text(verbatim: note).foregroundStyle(Theme.Color.textMuted).lineLimit(1)
            Text(verbatim: "↔ длинные строки прокручиваются").foregroundStyle(Theme.Color.textGutter).lineLimit(1).layoutPriority(-1)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if let practice {
                    Button { registry.selection = .practice(practice.ref) } label: { Text(verbatim: "Открыть практику") }
                        .buttonStyle(CompactButtonStyle())
                }
                Button { discarding = change } label: { Text(verbatim: "Отклонить") }
                    .buttonStyle(CompactButtonStyle())
                Button { Task { await registry.accept(change) } } label: { Text(verbatim: "Принять") }
                    .buttonStyle(CompactButtonStyle(prominent: true))
            }
        }
        .font(Theme.mono(12)).foregroundStyle(Theme.Color.text)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .overlay(alignment: .bottom) { Theme.Color.border.frame(height: 1) }
    }

    /// The advance of a character in `Theme.mono(12)`.
    private static let charWidth = ("0" as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]).width

    private func diffRow(_ line: DiffLine) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: line.number.map(String.init) ?? "").foregroundStyle(Theme.Color.textGutter)
                .frame(width: 36, alignment: .trailing).padding(.trailing, 10)
            Text(verbatim: line.sign).frame(width: 14, alignment: .leading)
                .foregroundStyle(line.sign == "+" ? Theme.Color.ok : line.sign == "-" ? Theme.Color.error : Theme.Color.textGutter)
            Text(verbatim: line.text).fixedSize()
                .foregroundStyle(line.sign == "@" ? Theme.Color.textMuted : Theme.Color.textCode)
        }
        .font(Theme.mono(12))
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, minHeight: 19, maxHeight: 19, alignment: .leading)
        .background(line.sign == "+" ? Theme.Color.ok.opacity(0.10) : .clear)
    }
}

/// One line of the diff pane: its number in the new file (the old one for removed lines), a
/// sign `+ - @` or none, the text.
struct DiffLine {
    var number: Int?
    var sign: String
    var text: String

    /// A new file comes as its content (`Registry.diff`), everything else as `git diff`.
    static func parse(_ diff: String, new: Bool) -> [DiffLine] {
        guard !diff.isEmpty else { return [] }
        var lines = diff.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        if new {
            return [DiffLine(sign: "@", text: "@@ -0,0 +1,\(lines.count) @@  new file mode 100644")]
                + lines.enumerated().map { DiffLine(number: $0.offset + 1, sign: "+", text: $0.element) }
        }
        var out: [DiffLine] = [], old = 0, now = 0, inHunk = false
        for line in lines {
            if line.hasPrefix("@@") {
                inHunk = true
                // @@ -a,b +c,d @@
                let parts = line.split(separator: " ")
                if parts.count > 2 {
                    old = parts[1].dropFirst().split(separator: ",").first.flatMap { Int($0) } ?? 0
                    now = parts[2].dropFirst().split(separator: ",").first.flatMap { Int($0) } ?? 0
                }
                out.append(DiffLine(sign: "@", text: line))
            } else if !inHunk {
                continue    // diff --git, index, ---, +++
            } else if line.hasPrefix("+") {
                out.append(DiffLine(number: now, sign: "+", text: String(line.dropFirst()))); now += 1
            } else if line.hasPrefix("-") {
                out.append(DiffLine(number: old, sign: "-", text: String(line.dropFirst()))); old += 1
            } else if line.hasPrefix("\\") {
                out.append(DiffLine(sign: "@", text: line))
            } else {
                out.append(DiffLine(number: now, sign: "", text: String(line.dropFirst()))); old += 1; now += 1
            }
        }
        return out
    }
}

extension Pending {
    var stateLabel: String { state == "new" ? "new" : state == "deleted" ? "del" : "mod" }
    var stateColor: Color { state == "new" ? Theme.Color.ok : state == "deleted" ? Theme.Color.error : Theme.Color.warn }

    /// `projects/<p>/services/<id>/<rest>` → (id, rest).
    var servicePath: (String, String)? {
        let parts = path.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(of: "services"), i + 2 < parts.count else { return nil }
        return (parts[i + 1], parts[(i + 2)...].joined(separator: "/"))
    }

    /// The practice the file is: `services/<id>/practices/<name>.py` or `chains/<name>.py`.
    var practice: Practice? {
        let parts = path.split(separator: "/").map(String.init)
        guard path.hasSuffix(".py"), parts.count >= 2 else { return nil }
        let name = String(parts[parts.count - 1].dropLast(3))
        if parts[parts.count - 2] == "chains" { return Practice(ref: "chains/" + name) }
        guard case let (id, rest)? = servicePath, rest == "practices/\(name).py" else { return nil }
        return Practice(ref: "\(id)/\(name)")
    }
}

/// Button in panels and rows: height 26 (24 in rows), padding 0 10 (12 prominent), radius 6.
struct CompactButtonStyle: ButtonStyle {
    var prominent = false
    var height: CGFloat = 26
    var fontSize: CGFloat = 13
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let prominent = prominent && enabled
        return configuration.label
            .font(Theme.ui(fontSize))
            .foregroundStyle(!enabled ? Theme.Color.textDisabled : prominent ? .white : Theme.Color.text)
            .padding(.horizontal, prominent ? 12 : 10).frame(height: height)
            .background(prominent ? Theme.Color.accent : Theme.Color.buttonBg, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(!enabled ? Theme.Color.border : prominent ? Theme.Color.accent : Theme.Color.borderButton))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
            .fixedSize()
    }
}
