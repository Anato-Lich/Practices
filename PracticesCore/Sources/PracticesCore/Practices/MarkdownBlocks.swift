import Foundation

/// The block structure of a markdown file, for views that render it natively: Foundation's
/// `AttributedString(markdown:)` gives the inline part (code, emphasis, links) but no layout of
/// headings, lists and code fences in SwiftUI's `Text`. Inline text is kept as markdown;
/// HTML comments (`<!-- обследование … -->`) are notes to agents and are left out.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// `marker` is `•` or the number with its dot; `indent` counts nesting (two spaces a level).
    case item(indent: Int, marker: String, text: String)
    case code(language: String?, text: String)
    /// Table rows as written: shown monospaced.
    case table(String)

    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        // Whether the next plain line continues the last paragraph or item.
        var open = false
        var fence: (language: String?, lines: [String], indent: Int)?
        // shortcut: comments are cut before fences are seen, so a `<!--` inside a code block goes too; fine for notes and conventions.
        let visible = markdown.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        for raw in visible.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let indent = raw.prefix { $0 == " " }.count
            let hashes = line.prefix { $0 == "#" }.count
            if var f = fence {
                if line.hasPrefix("```") {
                    blocks.append(.code(language: f.language, text: f.lines.joined(separator: "\n")))
                    fence = nil
                } else {
                    f.lines.append(String(raw.dropFirst(min(f.indent, indent))))
                    fence = f
                }
                continue
            }
            if line.hasPrefix("```") {
                let language = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                fence = (language.isEmpty ? nil : language, [], indent)
                open = false
            } else if line.isEmpty {
                open = false
            } else if (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") {
                blocks.append(.heading(level: hashes, text: line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces)))
                open = false
            } else if line.hasPrefix("|") {
                if case .table(let rows)? = blocks.last { blocks[blocks.count - 1] = .table(rows + "\n" + line) } else { blocks.append(.table(line)) }
                open = false
            } else if let (marker, text) = listItem(line) {
                blocks.append(.item(indent: indent / 2, marker: marker, text: text))
                open = true
            } else if open, let last = blocks.last {
                switch last {
                case .paragraph(let text): blocks[blocks.count - 1] = .paragraph(text + " " + line)
                case .item(let i, let m, let text): blocks[blocks.count - 1] = .item(indent: i, marker: m, text: text + " " + line)
                default: blocks.append(.paragraph(line))
                }
            } else {
                blocks.append(.paragraph(line))
                open = true
            }
        }
        if let f = fence { blocks.append(.code(language: f.language, text: f.lines.joined(separator: "\n"))) }
        return blocks
    }

    private static func listItem(_ line: String) -> (String, String)? {
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) { return ("•", String(line.dropFirst(2))) }
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return (digits + ".", String(line.dropFirst(digits.count + 2)))
    }
}
