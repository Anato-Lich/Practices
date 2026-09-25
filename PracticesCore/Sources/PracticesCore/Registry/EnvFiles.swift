import Foundation

/// An env file of a project that Practices keeps filled: the registry is the source, the file
/// is written from it (DECISIONS 48) — the way a new source reaches a project.
public struct ManagedFile: Codable, Hashable, Sendable {
    /// Relative to the project directory: `.env`, `.default.env`, `deploy/.deploy.env`.
    public var path: String
    public var sources: [SourceRef]
    /// Project variable → registry key, for projects that name variables their own way.
    public var env: [String: String]
    /// Registry keys to write; nil writes every key of the sources.
    public var only: [String]?

    public init(path: String, sources: [SourceRef], env: [String: String] = [:], only: [String]? = nil) {
        self.path = path; self.sources = sources; self.env = env; self.only = only
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        sources = try c.decodeIfPresent([SourceRef].self, forKey: .sources) ?? []
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        only = try c.decodeIfPresent([String].self, forKey: .only)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(sources, forKey: .sources)
        if !env.isEmpty { try c.encode(env, forKey: .env) }
        if let only { try c.encode(only, forKey: .only) }
    }

    enum CodingKeys: String, CodingKey { case path, sources, env, only }
}

/// Writes managed env files. Existing keys keep their line and only change their value; new
/// keys go into a marked block at the end; everything else in the file stays as it is.
public enum EnvFiles {

    public static let blockStart = "# >>> practices — values from ~/.practices; change them in Practices, then sync"
    public static let blockEnd = "# <<< practices"

    public enum State: String, Codable, Sendable { case same, changed, new, missingValue }

    /// One variable of a planned write. No value: only whether the file already holds it.
    public struct Line: Hashable, Sendable, Codable {
        public let variable: String
        public let key: String
        public let source: String
        public let env: String
        public let state: State
    }

    public struct Refused: Error, CustomStringConvertible, Sendable {
        public let description: String
    }

    /// Variables the file should hold: every key of its sources (or `only`), under the
    /// project's alias when it has one.
    static func wanted(_ file: ManagedFile, registry: Registry, store: SecretStore) throws -> [(variable: String, key: String, source: String, env: String, value: String?)] {
        var out: [(String, String, String, String, String?)] = []
        let aliasesByKey = Dictionary(grouping: file.env, by: \.value).mapValues { $0.map(\.key).sorted() }
        for ref in file.sources {
            let source = try registry.source(ref.source)
            let env = ref.env ?? source.defaultEnv
            let values = try store.values(source: source.id, env: env)
            for key in source.keys where file.only?.contains(key.name) ?? true {
                for variable in aliasesByKey[key.name] ?? [key.name] {
                    out.append((variable, key.name, source.id, env, values[key.name].flatMap { $0.isEmpty ? nil : $0 }))
                }
            }
        }
        return out
    }

    public static func plan(_ file: ManagedFile, project: URL, registry: Registry = Registry(),
                            store: SecretStore = SecretStore()) throws -> [Line] {
        let url = project.appendingPathComponent(file.path)
        let existing = (try? String(contentsOf: url, encoding: .utf8)).map(ConnectorsImport.parseDotenv) ?? []
        let current = Dictionary(existing.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
        return try wanted(file, registry: registry, store: store).map { w in
            let state: State = w.value == nil ? .missingValue
                : current[w.variable] == nil ? .new
                : current[w.variable] == w.value ? .same : .changed
            return Line(variable: w.variable, key: w.key, source: w.source, env: w.env, state: state)
        }
    }

    /// Writes the file; returns the plan it carried out. Refuses a file git would commit.
    @discardableResult
    public static func write(_ file: ManagedFile, project: URL, force: Bool = false,
                             registry: Registry = Registry(), store: SecretStore = SecretStore()) async throws -> [Line] {
        let url = project.appendingPathComponent(file.path)
        // A committed file (hyper-imu's `.default.env`) may hold plain settings, never secrets.
        let secretKeys = try file.sources.flatMap { try registry.source($0.source).keys.filter(\.secret).map(\.name) }
        let writesSecrets = try wanted(file, registry: registry, store: store).contains { secretKeys.contains($0.key) && $0.value != nil }
        if !force, writesSecrets, try await isTracked(url) {
            throw Refused(description: "\(file.path) is tracked by git (not in .gitignore) — secrets would be committed. Ignore it first, write only plain keys (--only), or --force.")
        }
        let lines = try plan(file, project: project, registry: registry, store: store)
        let values = Dictionary(try wanted(file, registry: registry, store: store).compactMap { w in w.value.map { (w.variable, $0) } },
                                uniquingKeysWith: { a, _ in a })
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = render(text, values: values, order: lines.map(\.variable))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let isNew = !FileManager.default.fileExists(atPath: url.path)
        if isNew { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        try updated.write(to: url, atomically: true, encoding: .utf8)
        // A file that now holds secrets is readable by its owner only, new or not.
        if isNew || writesSecrets { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        return lines
    }

    /// The new text: known variables replaced where they stand (every occurrence), the rest in
    /// the managed block, which is rebuilt each time.
    static func render(_ text: String, values: [String: String], order: [String]) -> String {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        // Drop the old block; its keys are placed again below.
        if let start = lines.firstIndex(of: blockStart) {
            let end = lines[start...].firstIndex(of: blockEnd) ?? (lines.count - 1)
            lines.removeSubrange(start...end)
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        }
        var placed = Set<String>()
        for (i, line) in lines.enumerated() {
            guard let (prefix, name) = assignment(line), let value = values[name] else { continue }
            lines[i] = prefix + name + "=" + quoted(value)
            placed.insert(name)
        }
        var seen = Set<String>()
        let rest = order.filter { !placed.contains($0) && values[$0] != nil && seen.insert($0).inserted }
        if !rest.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append(blockStart)
            lines += rest.map { "\($0)=" + quoted(values[$0]!) }
            lines.append(blockEnd)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `export NAME=…` / `NAME=…` → (prefix, NAME).
    static func assignment(_ line: String) -> (String, String)? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        let indent = String(line.prefix(line.count - trimmed.count))
        var body = Substring(trimmed)
        var prefix = indent
        if body.hasPrefix("export ") { prefix += "export "; body = body.dropFirst(7) }
        guard let eq = body.firstIndex(of: "=") else { return nil }
        let name = String(body[..<eq]).trimmingCharacters(in: .whitespaces)
        guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else { return nil }
        return (prefix, name)
    }

    /// Plain when safe; double-quoted (with `\` and `"` escaped) when the value has spaces,
    /// `#`, quotes, `$` or `=`, which dotenv parsers treat differently.
    static func quoted(_ value: String) -> String {
        let special = CharacterSet(charactersIn: " \t#\"'$`\\=")
        guard value.rangeOfCharacter(from: special) != nil else { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// True when the file is inside a git repository and not ignored there — writing secrets
    /// to it would put them one `git add` away from a commit.
    static func isTracked(_ url: URL) async throws -> Bool {
        var probe = url.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: probe.path) { probe.deleteLastPathComponent() }
        guard (try? await Shell.run("git", ["-C", probe.path, "rev-parse", "--is-inside-work-tree"])) != nil else { return false }
        // check-ignore exits 0 when the path is ignored, 1 when it is not.
        let ignored = (try? await Shell.run("git", ["-C", probe.path, "check-ignore", "-q", url.path])) != nil
        return !ignored
    }
}

/// Connecting sources to projects and keeping their files current.
public enum ProjectFiles {

    /// Adds (or replaces) a managed file in the project's manifest, then writes it.
    @discardableResult
    public static func connect(_ file: ManagedFile, project: URL, force: Bool = false) async throws -> [EnvFiles.Line] {
        var manifest = ProjectManifest.load(project) ?? ProjectManifest(sources: [])
        if let i = manifest.files.firstIndex(where: { $0.path == file.path }) {
            var merged = manifest.files[i]
            for ref in file.sources {
                merged.sources.removeAll { $0.source == ref.source }
                merged.sources.append(ref)
            }
            merged.env.merge(file.env) { _, new in new }
            if let only = file.only { merged.only = Array(Set((merged.only ?? []) + only)).sorted() }
            manifest.files[i] = merged
        } else {
            manifest.files.append(file)
        }
        for ref in file.sources where !manifest.sources.contains(where: { $0.source == ref.source }) {
            manifest.sources.append(ref)
        }
        let target = manifest.files.first { $0.path == file.path }!
        let lines = try await EnvFiles.write(target, project: project, force: force)
        try manifest.save(to: project)
        return lines
    }

    public struct FileStatus: Sendable {
        public let project: URL
        public let file: ManagedFile
        public let lines: [EnvFiles.Line]
        public var stale: Bool { lines.contains { $0.state == .changed || $0.state == .new } }
    }

    /// Every managed file of every project, with what a sync would change.
    public static func status(root: String = Monitor.projectsRoot()) -> [FileStatus] {
        ProjectManifest.all(root: root).flatMap { project in
            project.manifest.files.compactMap { file in
                (try? EnvFiles.plan(file, project: project.dir)).map { FileStatus(project: project.dir, file: file, lines: $0) }
            }
        }
    }

    /// Rewrites the stale files; returns them.
    public static func sync(_ statuses: [FileStatus], force: Bool = false) async throws -> [FileStatus] {
        var done: [FileStatus] = []
        for s in statuses where s.stale {
            try await EnvFiles.write(s.file, project: s.project, force: force)
            done.append(s)
        }
        return done
    }
}
