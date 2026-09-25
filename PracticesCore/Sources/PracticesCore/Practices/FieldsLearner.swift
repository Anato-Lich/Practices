import Foundation

/// Adds field paths seen in runs to the source's `fields.yaml` (DECISIONS 24): the type is
/// filled in, the meaning stays for a person or the agent to write. A chain's own result is
/// its last step's, so fields are credited to the sources of the steps that produced them.
public enum FieldsLearner {

    /// Returns the sources whose dictionaries grew, with how many paths each gained.
    @discardableResult
    public static func learn(from result: PracticeResult, practice: Practice,
                             registry: Registry = Registry()) async -> [String: Int] {
        guard result.ok else { return [:] }
        var bySource: [String: [PracticeResult.Field]] = [:]
        if let source = practice.source, let schema = result.schema {
            bySource[source, default: []] += schema
        }
        for step in result.steps where step.ok {
            if let source = Practice(ref: step.ref).source, let schema = step.schema {
                bySource[source, default: []] += schema
            }
        }
        var gained: [String: Int] = [:]
        for (source, fields) in bySource {
            var known = registry.fields(of: source)
            let paths = Set(known.map(\.path))
            var added = 0
            for field in fields where !paths.contains(field.path) && !known.contains(where: { $0.path == field.path }) {
                known.append(FieldDoc(path: field.path, type: field.type))
                added += 1
            }
            guard added > 0 else { continue }
            known.sort { $0.path < $1.path }
            try? registry.saveFields(known, of: source)
            gained[source] = added
        }
        if !gained.isEmpty {
            let summary = gained.sorted { $0.key < $1.key }.map { "\($0.key) +\($0.value)" }.joined(separator: ", ")
            _ = try? await registry.commit("Fields seen in runs of \(practice.ref): \(summary)")
        }
        return gained
    }
}
