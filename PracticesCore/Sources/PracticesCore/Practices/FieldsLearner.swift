import Foundation

/// Adds field paths seen in runs to the service's `fields.yaml` (DECISIONS 24): the type is
/// filled in, the meaning stays for a person or the agent to write. A chain's own result is
/// its last step's, so fields are credited to the services of the steps that produced them.
public enum FieldsLearner {

    /// Returns the services whose dictionaries grew, with how many paths each gained.
    @discardableResult
    public static func learn(from result: PracticeResult, practice: Practice,
                             registry: Registry = Registry()) async -> [String: Int] {
        guard result.ok else { return [:] }
        var byService: [String: [PracticeResult.Field]] = [:]
        if let service = practice.service, let schema = result.schema {
            byService[service, default: []] += schema
        }
        for step in result.steps where step.ok {
            if let service = Practice(ref: step.ref).service, let schema = step.schema {
                byService[service, default: []] += schema
            }
        }
        var gained: [String: Int] = [:]
        var files: [URL] = []
        for (service, fields) in byService {
            var known = registry.fields(of: service)
            let paths = Set(known.map(\.path))
            var added = 0
            for field in fields where !paths.contains(field.path) && !known.contains(where: { $0.path == field.path }) {
                known.append(FieldDoc(path: field.path, type: field.type))
                added += 1
            }
            guard added > 0 else { continue }
            known.sort { $0.path < $1.path }
            guard let file = try? registry.saveFields(known, of: service) else { continue }
            files.append(file)
            gained[service] = added
        }
        if !gained.isEmpty {
            let summary = gained.sorted { $0.key < $1.key }.map { "\($0.key) +\($0.value)" }.joined(separator: ", ")
            _ = try? await registry.commit("Fields seen in runs of \(practice.ref): \(summary)", files)
        }
        return gained
    }
}
