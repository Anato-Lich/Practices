import Foundation

/// Code in ~/Projects that mentions something — the last group of search: logic worth turning
/// into a practice (mock-up board 6, "В коде проектов · ещё не практика").
public struct CodeHit: Codable, Hashable, Sendable {
    public let path: String
    public let line: Int
    public let excerpt: String
    /// The Python function the match is inside, when there is one.
    public let function: String?
}

public enum ProjectCode {

    static let extensions: Set<String> = ["py", "ts", "tsx", "js", "sql", "go", "swift"]

    public static func search(_ query: String, root: String = Monitor.projectsRoot(), limit: Int = 200) async -> (hits: [CodeHit], files: Int) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.utf8.count >= 4 else { return ([], 0) }
        let files = Doctor.collect(root: root).text.filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }
        let found = await MultiSearch([q]).scan(files)
        var hits: [CodeHit] = []
        for path in found.keys.sorted() {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: "\n")
            // One hit per file — the list is of places, not occurrences — preferring a match
            // inside a function (a comment above the function often mentions the field first).
            var chosen: CodeHit?
            for (i, line) in lines.enumerated() where line.contains(q) {
                let function = path.hasSuffix(".py") ? enclosingFunction(lines, at: i) : nil
                let hit = CodeHit(path: path, line: i + 1, excerpt: line.trimmingCharacters(in: .whitespaces).prefix(200).description,
                                  function: function)
                if chosen == nil { chosen = hit }
                if function != nil { chosen = hit; break }
            }
            if let chosen { hits.append(chosen) }
        }
        // Functions in application code first (what can become practices), tests last.
        func rank(_ h: CodeHit) -> Int {
            let test = h.path.contains("/tests/") || h.path.contains("/test_") || (h.path as NSString).lastPathComponent.hasPrefix("test_")
            return (test ? 2 : 0) + (h.function == nil ? 1 : 0)
        }
        hits.sort { (rank($0), $0.path) < (rank($1), $1.path) }
        return (Array(hits.prefix(limit)), found.count)
    }

    /// The nearest `def` above the line with less indentation.
    static func enclosingFunction(_ lines: [String], at index: Int) -> String? {
        let indent = lines[index].prefix { $0 == " " }.count
        for i in stride(from: index, through: 0, by: -1) {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("def ") || trimmed.hasPrefix("async def ") else { continue }
            if line.prefix(while: { $0 == " " }).count < indent || i == index {
                let afterDef = trimmed.components(separatedBy: "def ").dropFirst().joined(separator: "def ")
                return afterDef.prefix { $0 != "(" }.description
            }
        }
        return nil
    }

    /// A draft practice from a Python function in a project: the file's imports, the function,
    /// and `run` pointing at it. A starting point to edit, not a finished practice.
    public static func draft(from path: String, function name: String, ref: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("def \(name)(") || t.hasPrefix("async def \(name)(")
        }) else { return nil }
        let indent = lines[start].prefix { $0 == " " }.count
        var begin = start
        while begin > 0, lines[begin - 1].trimmingCharacters(in: .whitespaces).hasPrefix("@") { begin -= 1 }
        var end = start + 1
        while end < lines.count {
            let line = lines[end]
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty && line.prefix(while: { $0 == " " }).count <= indent && !t.hasPrefix("#") { break }
            end += 1
        }
        let body = lines[begin..<end].map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " }.count))) }
            .joined(separator: "\n").trimmingCharacters(in: .newlines)
        let imports = lines.filter { $0.hasPrefix("import ") || $0.hasPrefix("from ") }.joined(separator: "\n")
        // Module-level constants the function mentions (`_MOVE_START = (2, 3)`), one line each.
        let constantRegex = try! NSRegularExpression(pattern: #"^([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^=]+)?=\s*[^=]"#)
        let constants = lines.filter { line in
            guard let m = constantRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let r = Range(m.range(at: 1), in: line) else { return false }
            let name = String(line[r])
            return name != name.lowercased() && body.range(of: #"\b\#(name)\b"#, options: .regularExpression) != nil
        }.joined(separator: "\n")
        let home = NSHomeDirectory() + "/"
        let origin = path.hasPrefix(home) ? String(path.dropFirst(home.count)) : path
        return """
            # practices: \(ref)
            # Draft from \(origin):\(start + 1) (\(name)). Imports are the source file's: drop what
            # this function does not need, inline what it needs from its project, then save (⌘S).
            \(imports)
            \(constants.isEmpty ? "" : "\n" + constants)


            \(body)


            run = \(name)

            """
    }
}
