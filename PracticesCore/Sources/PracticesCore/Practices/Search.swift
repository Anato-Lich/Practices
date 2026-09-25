import Foundation

/// Search by meaning, not by name (DECISIONS 25): a field in a dictionary, practices whose
/// result holds it, documents and notes that mention it, practices whose code does. The same
/// groups serve the window and the MCP `search` tool.
public struct SearchResults: Sendable, Codable {
    public struct FieldHit: Hashable, Sendable, Codable {
        public let source: String
        public let field: FieldDoc
    }
    public struct ResultHit: Hashable, Sendable, Codable {
        public let practice: String
        public let path: String
        public let type: String
        /// Rows that had the field / rows sampled, from the latest successful run.
        public let present: Int
        public let seen: Int
        /// True when the field came from a step of a chain rather than its final result.
        public let viaStep: String?
    }
    public struct TextHit: Hashable, Sendable, Codable {
        public let title: String
        public let source: String?
        public let path: String
        public let excerpt: String
    }

    public var fields: [FieldHit] = []
    public var results: [ResultHit] = []
    public var docs: [TextHit] = []
    public var code: [TextHit] = []

    public init() {}

    public var isEmpty: Bool { fields.isEmpty && results.isEmpty && docs.isEmpty && code.isEmpty }
}

public enum Search {

    public static func run(_ query: String, registry: Registry = Registry(),
                           store: PracticeStore? = nil, runs: RunsStore? = try? RunsStore()) -> SearchResults {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return SearchResults() }
        let store = store ?? PracticeStore(registry: registry)
        var out = SearchResults()

        // Fields: path, last path component or meaning.
        for id in registry.sourceIDs() {
            for field in registry.fields(of: id) where matches(field.path, q) || (field.meaning?.lowercased().contains(q) ?? false) {
                out.fields.append(.init(source: id, field: field))
            }
        }
        out.fields.sort { rank($0.field.path, q) < rank($1.field.path, q) }

        // Practices whose latest result schema has the field (steps included for chains).
        let decoder = JSONDecoder()
        for record in latestRuns(runs) {
            if let data = record.schema?.data(using: .utf8),
               let schema = try? decoder.decode([PracticeResult.Field].self, from: data) {
                for f in schema where matches(f.path, q) {
                    out.results.append(.init(practice: record.ref, path: f.path, type: f.type,
                                             present: f.present, seen: f.seen, viaStep: nil))
                }
            }
        }
        // Practices that ran as steps of a chain: their output schema was kept with the step.
        var stepSeen = Set(out.results.map(\.practice))
        for record in latestRuns(runs) {
            guard let data = record.steps?.data(using: .utf8),
                  let steps = try? decoder.decode([StepRecord].self, from: data) else { continue }
            for step in steps where step.ok && !stepSeen.contains(step.ref) {
                for f in step.schema ?? [] where matches(f.path, q) {
                    out.results.append(.init(practice: step.ref, path: f.path, type: f.type,
                                             present: f.present, seen: f.seen, viaStep: nil))
                    stepSeen.insert(step.ref)
                    break
                }
            }
        }
        // A chain whose steps hold the field: through the step practices' own schemas.
        let direct = Set(out.results.map(\.practice))
        for chain in store.chains() where !direct.contains(chain.ref) {
            for dep in store.dependencies(of: chain) {
                if let hit = out.results.first(where: { $0.practice == dep.ref && $0.viaStep == nil }) {
                    out.results.append(.init(practice: chain.ref, path: hit.path, type: hit.type,
                                             present: hit.present, seen: hit.seen, viaStep: dep.ref))
                    break
                }
            }
        }

        // Documents and notes, full text.
        for id in registry.sourceIDs() {
            if let notes = registry.notes(of: id), let excerpt = excerpt(notes, q) {
                out.docs.append(.init(title: "Notes", source: id, path: registry.dir(of: id).appendingPathComponent("notes.md").path, excerpt: excerpt))
            }
            for doc in registry.docs(of: id) {
                guard let path = doc.path else { continue }
                let file = path.hasPrefix("/") ? path : registry.dir(of: id).appendingPathComponent("docs/\(path)").path
                guard var text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
                if let section = doc.section { text = Self.section(section, of: text) ?? text }
                if let excerpt = excerpt(text, q) {
                    out.docs.append(.init(title: doc.title, source: id, path: file, excerpt: excerpt))
                }
            }
        }

        // One document attached to several sources is one hit.
        var byPath: [String: SearchResults.TextHit] = [:]
        var order: [String] = []
        for hit in out.docs {
            if let existing = byPath[hit.path] {
                let sources = [existing.source, hit.source].compactMap { $0 }.joined(separator: ", ")
                byPath[hit.path] = SearchResults.TextHit(title: existing.title, source: sources, path: hit.path, excerpt: existing.excerpt)
            } else {
                byPath[hit.path] = hit
                order.append(hit.path)
            }
        }
        out.docs = order.compactMap { byPath[$0] }

        // Code and docstrings of practices.
        for practice in store.all() {
            guard let code = try? store.code(of: practice), let excerpt = excerpt(code, q) else { continue }
            out.code.append(.init(title: practice.ref, source: practice.source, path: store.url(of: practice).path, excerpt: excerpt))
        }
        return out
    }

    static func latestRuns(_ runs: RunsStore?) -> [RunRecord] {
        guard let runs else { return [] }
        var seen = Set<String>()
        return runs.recent(limit: 2000).filter { $0.ok && $0.schema != nil && seen.insert($0.ref).inserted }
    }

    static func matches(_ path: String, _ q: String) -> Bool {
        path.lowercased().contains(q)
    }

    /// Exact last component first, then exact path, then anything containing the query.
    static func rank(_ path: String, _ q: String) -> Int {
        let p = path.lowercased()
        if p.split(separator: ".").last.map(String.init) == q { return 0 }
        if p == q { return 1 }
        return 2
    }

    /// The line holding the match, trimmed around it.
    static func excerpt(_ text: String, _ q: String) -> String? {
        guard let range = text.range(of: q, options: .caseInsensitive) else { return nil }
        let lineStart = text[..<range.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[range.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        var line = String(text[lineStart..<lineEnd]).trimmingCharacters(in: .whitespaces)
        if line.count > 220, let r = line.range(of: q, options: .caseInsensitive) {
            let start = line.index(r.lowerBound, offsetBy: -80, limitedBy: line.startIndex) ?? line.startIndex
            let end = line.index(r.upperBound, offsetBy: 120, limitedBy: line.endIndex) ?? line.endIndex
            line = (start > line.startIndex ? "…" : "") + line[start..<end] + (end < line.endIndex ? "…" : "")
        }
        return line
    }

    /// The part of a markdown file under a `## heading` (to the next heading of that level).
    static func section(_ heading: String, of text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("#") && $0.contains(heading) }) else { return nil }
        let level = lines[start].prefix { $0 == "#" }.count
        let end = lines[(start + 1)...].firstIndex { line in
            let hashes = line.prefix { $0 == "#" }.count
            return hashes > 0 && hashes <= level
        } ?? lines.endIndex
        return lines[start..<end].joined(separator: "\n")
    }
}
