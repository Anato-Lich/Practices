import Foundation

/// Code in ~/Projects that mentions something — the last group of search: logic that is not a
/// practice yet.
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
}
