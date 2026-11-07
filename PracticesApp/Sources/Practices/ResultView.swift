import SwiftUI
import PracticesCore

/// A practice's output as a table, a JSON tree or text — whichever shape it has — with JSON
/// and stdout one click away. A single row reads as «поле / тип / значение» (design board).
struct ResultView: View {
    let shape: String?
    let columns: [String]
    let rows: [[JSONValue]]
    let tree: JSONValue?
    let text: String?
    let stdout: String
    var schema: [PracticeResult.Field] = []
    @State private var tab: Tab = .auto

    enum Tab: Hashable { case auto, json, stdout }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Not in the design: the JSON and stdout views the window had; kept as quiet links.
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                tabLink(shape == "table" ? "таблица" : shape == "tree" ? "дерево" : "текст", .auto)
                tabLink("json", .json)
                if !stdout.isEmpty { tabLink("stdout", .stdout) }
            }
            switch tab {
            case .auto:
                switch shape {
                case "table": ResultTable(columns: columns, rows: rows, schema: schema)
                case "tree": JSONTree(value: tree ?? .null)
                case "none": quiet("нет результата")
                default: ResultText(text: text ?? "")
                }
            case .json:
                JSONTree(value: shape == "table" ? .array(rows.map { row in
                    let pairs = zip(columns, row)
                    return .object(Dictionary(pairs.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a }), order: columns)
                }) : (tree ?? .string(text ?? "")))
            case .stdout:
                ResultText(text: stdout)
            }
        }
    }

    private func tabLink(_ title: String, _ value: Tab) -> some View {
        Button { tab = value } label: {
            Text(verbatim: title).font(Theme.mono(11)).foregroundStyle(tab == value ? Theme.Color.text : Theme.Color.textMuted)
        }
        .buttonStyle(.plain)
    }

    private func quiet(_ text: String) -> some View {
        Text(verbatim: text).font(Theme.ui(12)).foregroundStyle(Theme.Color.textMuted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The design's table: mono 12, header muted 500 over a `border` line, rows padding 5 8 over
/// `border.soft`. One row is shown transposed: field, type (builtin-type colour), value (secondary).
struct ResultTable: View {
    let columns: [String]
    let rows: [[JSONValue]]
    var schema: [PracticeResult.Field] = []

    static let typeColor = Color(hex: 0x4FD1D9)
    static let cellWidth: CGFloat = 160

    var body: some View {
        if rows.count == 1 {
            let row = rows[0]
            ScrollView {
                VStack(spacing: 0) {
                    line([header("поле"), header("тип"), header("значение")], border: Theme.Color.border)
                    ForEach(columns.indices, id: \.self) { i in
                        let value = i < row.count ? row[i] : .null
                        line([cell(columns[i], Theme.Color.text),
                              cell(schema.first { $0.path == columns[i] }?.type ?? value.typeName, Self.typeColor),
                              cell(value.cellText, Theme.Color.textSecondary)], border: Theme.Color.borderSoft)
                    }
                }
            }
        } else {
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    Section {
                        ForEach(rows.indices, id: \.self) { r in
                            line(columns.indices.map { c in cell(c < rows[r].count ? rows[r][c].cellText : "", Theme.Color.text) },
                                 border: Theme.Color.borderSoft, fixed: true)
                        }
                    } header: {
                        line(columns.map(header), border: Theme.Color.border, fixed: true).background(Theme.Color.windowBg)
                    }
                }
            }
        }
    }

    private func header(_ title: String) -> Text {
        Text(verbatim: title).font(Theme.mono(12, .medium)).foregroundColor(Theme.Color.textMuted)
    }

    private func cell(_ value: String, _ color: Color) -> Text {
        Text(verbatim: value).font(Theme.mono(12)).foregroundColor(color)
    }

    /// Cells share the width in the transposed view; a wide table gets fixed columns and scrolls.
    private func line(_ cells: [Text], border: Color, fixed: Bool = false) -> some View {
        HStack(spacing: 0) {
            ForEach(cells.indices, id: \.self) { i in
                cells[i].lineLimit(1).truncationMode(.tail).textSelection(.enabled)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(width: fixed ? Self.cellWidth : nil, alignment: .leading)
                    .frame(maxWidth: fixed ? nil : .infinity, alignment: .leading)
            }
        }
        .overlay(alignment: .bottom) { border.frame(height: 1) }
    }
}

extension JSONValue {
    /// The value's type as the runner's schema names it.
    var typeName: String {
        switch self {
        case .null: "null"
        case .bool: "bool"
        case .int: "int"
        case .number: "float"
        case .string: "str"
        case .array: "list"
        case .object: "dict"
        }
    }
}

/// Selectable mono text in the result area (the shared `MonoText` keeps its look for the diff).
struct ResultText: View {
    let text: String
    var color = Theme.Color.textCode
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(verbatim: text).font(Theme.mono(12)).foregroundStyle(color).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.vertical, 6)
        }
    }
}

/// Collapsible JSON.
struct JSONTree: View {
    let value: JSONValue

    struct Node: Identifiable {
        let id = UUID()
        let key: String
        let value: JSONValue
        var children: [Node]? {
            switch value {
            case .array(let items): return items.enumerated().map { Node(key: "[\($0.offset)]", value: $0.element) }
            case .object(let dict, let order): return order.compactMap { k in dict[k].map { Node(key: k, value: $0) } }
            default: return nil
            }
        }
        var summary: String {
            switch value {
            case .array(let a): return "[\(a.count)]"
            case .object(let o, _): return "{\(o.count)}"
            case .string(let s): return "\"\(s)\""
            default: return value.cellText
            }
        }
    }

    var body: some View {
        List {
            OutlineGroup(Node(key: "result", value: value).children ?? [Node(key: "result", value: value)], children: \.children) { node in
                HStack(spacing: 6) {
                    Text(verbatim: node.key).font(Theme.mono(12)).foregroundStyle(Theme.Color.textMuted)
                    Text(verbatim: node.summary).font(Theme.mono(12)).foregroundStyle(Theme.Color.textSecondary).lineLimit(1)
                        .textSelection(.enabled)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

struct MonoText: View {
    let text: String
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(verbatim: text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(10)
        }
    }
}
