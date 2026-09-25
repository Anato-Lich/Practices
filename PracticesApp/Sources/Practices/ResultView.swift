import SwiftUI
import PracticesCore

/// A practice's output as a table, a JSON tree or text — whichever shape it has — with
/// stdout beside it (mock-up board 2).
struct ResultView: View {
    let shape: String?
    let columns: [String]
    let rows: [[JSONValue]]
    let tree: JSONValue?
    let text: String?
    let stdout: String
    @State private var tab: Tab = .auto

    enum Tab: Hashable { case auto, json, stdout }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text(shape == "table" ? "Table" : shape == "tree" ? "Tree" : "Text").tag(Tab.auto)
                Text("JSON").tag(Tab.json)
                Text(verbatim: "stdout").tag(Tab.stdout)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.vertical, 6)
            Divider()
            switch tab {
            case .auto:
                switch shape {
                case "table": ResultTable(columns: columns, rows: rows)
                case "tree": JSONTree(value: tree ?? .null)
                case "none": ContentUnavailableView("No result", systemImage: "circle.dashed")
                default: MonoText(text: text ?? "")
                }
            case .json:
                JSONTree(value: shape == "table" ? .array(rows.map { row in
                    let pairs = zip(columns, row)
                    return .object(Dictionary(pairs.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a }), order: columns)
                }) : (tree ?? .string(text ?? "")))
            case .stdout:
                if stdout.isEmpty { ContentUnavailableView("Nothing printed", systemImage: "text.alignleft") }
                else { MonoText(text: stdout) }
            }
        }
    }
}

struct ResultTable: View {
    let columns: [String]
    let rows: [[JSONValue]]

    struct Row: Identifiable {
        let id: Int
        let cells: [String]
    }
    struct Column: Identifiable {
        let id: Int
        let name: String
    }

    var body: some View {
        let data = rows.enumerated().map { Row(id: $0.offset, cells: $0.element.map(\.cellText)) }
        let cols = columns.enumerated().map { Column(id: $0.offset, name: $0.element) }
        Table(data) {
            TableColumnForEach(cols) { column in
                TableColumn(column.name) { row in
                    Text(verbatim: column.id < row.cells.count ? row.cells[column.id] : "")
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .textSelection(.enabled)
                        .help(column.id < row.cells.count ? row.cells[column.id] : "")
                }
                .width(min: 60, ideal: 140)
            }
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
                    Text(verbatim: node.key).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    Text(verbatim: node.summary).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                        .textSelection(.enabled)
                }
            }
        }
        .listStyle(.plain)
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
