import Foundation

/// A practice copied into a project, found by its marker line `# practices: <ref>@v<N>`
/// (DECISIONS 5).
public struct PracticeCopy: Codable, Hashable, Sendable {
    public enum State: String, Codable, Sendable {
        case current        // the latest version, unchanged
        case outdated       // an older version, unchanged: can be updated
        case modified       // differs from the version it names: changed in the project
        case unknown        // the marker names a practice or version the registry lacks
    }
    public let ref: String
    public let version: Int?
    public let path: String
    public let line: Int
    public let latest: Int
    public let state: State
}

public enum Copies {

    static let marker = try! NSRegularExpression(pattern: #"#\s*practices:\s*([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(?:@v(\d+))?"#)

    /// The marker line for a version, as `get_practice` hands code out.
    public static func markerLine(_ ref: String, version: Int) -> String { "# practices: \(ref)@v\(version)" }

    /// Code with its first marker line set to `ref@vN` (or one added on top).
    public static func stamped(_ code: String, ref: String, version: Int) -> String {
        var lines = code.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("# practices:") }) {
            lines[i] = markerLine(ref, version: version)
        } else {
            lines.insert(markerLine(ref, version: version), at: 0)
        }
        return lines.joined(separator: "\n")
    }

    /// Every marked copy under the projects root (the registry itself is not a project).
    public static func scan(root: String = Monitor.projectsRoot(), store: PracticeStore = PracticeStore()) async -> [PracticeCopy] {
        let files = Doctor.collect(root: root).text.filter { $0.hasSuffix(".py") }
        var found: [(ref: String, version: Int?, path: String, line: Int, text: String)] = []
        for path in files {
            guard let data = FileManager.default.contents(atPath: path),
                  data.range(of: Data("practices:".utf8)) != nil,
                  let text = String(data: data, encoding: .utf8) else { continue }
            let ns = text as NSString
            for m in marker.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let ref = ns.substring(with: m.range(at: 1))
                let version = m.range(at: 2).location == NSNotFound ? nil : Int(ns.substring(with: m.range(at: 2)))
                let line = ns.substring(to: m.range.location).components(separatedBy: "\n").count
                found.append((ref, version, path, line, text))
            }
        }
        var versionsCache: [String: [PracticeVersion]] = [:]
        var out: [PracticeCopy] = []
        for copy in found {
            let practice = Practice(ref: copy.ref)
            if versionsCache[copy.ref] == nil { versionsCache[copy.ref] = (try? await store.versions(of: practice)) ?? [] }
            let versions = versionsCache[copy.ref]!
            guard !versions.isEmpty, let v = copy.version, v >= 1, v <= versions.count else {
                out.append(.init(ref: copy.ref, version: copy.version, path: copy.path, line: copy.line, latest: versions.count, state: .unknown))
                continue
            }
            let original = (try? await store.code(of: practice, at: versions[v - 1])) ?? ""
            let same = normalized(copy.text) == normalized(stamped(original, ref: copy.ref, version: v))
                || copy.text.contains(body(of: original))
            let state: PracticeCopy.State = !same ? .modified : (v == versions.count ? .current : .outdated)
            out.append(.init(ref: copy.ref, version: v, path: copy.path, line: copy.line, latest: versions.count, state: state))
        }
        return out.sorted { ($0.ref, $0.path) < ($1.ref, $1.path) }
    }

    static func normalized(_ text: String) -> String {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// The code without its marker line: a copy pasted into a bigger file still contains it.
    static func body(of code: String) -> String {
        code.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("# practices:") }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
