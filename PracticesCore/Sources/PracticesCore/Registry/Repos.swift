import Foundation

/// A repository as «Не распределено» shows it: found on a hosting of a space or as a local
/// clone, and not in any project yet. The list decides nothing (DECISIONS 15).
public struct RepoInfo: Codable, Hashable, Sendable {
    public let repo: RepoID
    /// The space whose hosting lists it; nil for a clone no space's hosting lists.
    public var space: String?
    public var archived = false
    public var lastActivity: Date?
    public var description: String?
    /// The GitLab subgroup it is in — a suggestion for the project's name, nothing more.
    public var suggestedProject: String?
    /// Where its clone is on this machine.
    public var clone: String?
    /// Listed in a space's `ignore`: left out of the list unless asked for.
    public var ignored = false
}

public enum Repos {

    // MARK: Local clones

    /// Repository → its clone, for every `.git` directory under the roots (at most four levels
    /// down) whose `origin` is a remote address. This finds a place, not a structure
    /// (DECISIONS 3). A `.git` file is a worktree or a submodule and is skipped.
    public static func clones(roots: [String]) -> [RepoID: String] {
        var out: [RepoID: String] = [:]
        let fm = FileManager.default
        func walk(_ dir: URL, depth: Int) {
            guard depth <= 4, let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path, isDirectory: &isDir), isDir.boolValue,
               let config = try? String(contentsOf: dir.appendingPathComponent(".git/config"), encoding: .utf8),
               let id = origin(inGitConfig: config).flatMap(RepoID.init), out[id] == nil {
                out[id] = dir.path
            }
            for name in names.sorted() where !name.hasPrefix(".") && !Doctor.skippedDirs.contains(name) {
                let url = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { walk(url, depth: depth + 1) }
            }
        }
        for root in roots { walk(URL(fileURLWithPath: root), depth: 0) }
        return out
    }

    /// `url` of `[remote "origin"]`, read from the file: no `git` process per repository.
    static func origin(inGitConfig text: String) -> String? {
        var inOrigin = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inOrigin = line.replacingOccurrences(of: " ", with: "") == "[remote\"origin\"]"; continue }
            guard inOrigin, line.hasPrefix("url"), let eq = line.firstIndex(of: "=") else { continue }
            return line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: Hosting

    /// Repositories of one `hosting` entry, through `gh` or `glab`: their login is the tools'
    /// own, no token is kept here (DECISIONS 16).
    public static func hosted(_ hosting: Space.Hosting) async throws -> [RepoInfo] {
        if hosting.host.lowercased() == "github.com" {
            let json = try await Shell.run("gh", ["repo", "list", hosting.owner, "--limit", "1000",
                                                  "--json", "nameWithOwner,isArchived,pushedAt,description"])
            return try parseGitHub(json)
        }
        // Not `simple=true`: the short form has no `archived`.
        let group = hosting.owner.replacingOccurrences(of: "/", with: "%2F")
        var out: [RepoInfo] = []
        for page in 1...50 {
            let json = try await Shell.run("glab", ["api", "--hostname", hosting.host,
                                                    "groups/\(group)/projects?include_subgroups=true&per_page=100&page=\(page)"])
            let repos = try parseGitLab(json, hosting: hosting)
            out += repos
            if repos.count < 100 { break }
        }
        return out
    }

    private struct GitHubRepo: Decodable {
        let nameWithOwner: String
        let isArchived: Bool?
        let pushedAt: String?
        let description: String?
    }

    private struct GitLabProject: Decodable {
        let path_with_namespace: String
        let archived: Bool?
        let last_activity_at: String?
        let description: String?
    }

    static func parseGitHub(_ json: String) throws -> [RepoInfo] {
        try JSONDecoder().decode([GitHubRepo].self, from: Data(json.utf8)).compactMap { r in
            RepoID("github.com/" + r.nameWithOwner).map {
                RepoInfo(repo: $0, archived: r.isArchived ?? false, lastActivity: date(r.pushedAt), description: nonEmpty(r.description))
            }
        }
    }

    static func parseGitLab(_ json: String, hosting: Space.Hosting) throws -> [RepoInfo] {
        try JSONDecoder().decode([GitLabProject].self, from: Data(json.utf8)).compactMap { p in
            guard let id = RepoID(hosting.host + "/" + p.path_with_namespace) else { return nil }
            // owner/x-vision/x-vision-cloud → x-vision: the first group below the listed one.
            let below = p.path_with_namespace.lowercased().dropFirst(hosting.owner.count + 1).split(separator: "/")
            return RepoInfo(repo: id, archived: p.archived ?? false, lastActivity: date(p.last_activity_at),
                            description: nonEmpty(p.description), suggestedProject: below.count > 1 ? String(below[0]) : nil)
        }
    }

    private static func nonEmpty(_ text: String?) -> String? { (text ?? "").isEmpty ? nil : text }

    /// GitHub writes whole seconds, GitLab fractions.
    private static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)
    }

    // MARK: Unassigned

    /// Hosted repositories plus local clones, minus the ones a project of any space has. Each
    /// knows its clone and whether a space ignores it.
    public static func unassigned(hosted: [RepoInfo], clones: [RepoID: String], assigned: Set<RepoID>,
                                  ignored: Set<RepoID> = []) -> [RepoInfo] {
        var byID: [RepoID: RepoInfo] = [:]
        for repo in hosted where byID[repo.repo] == nil { byID[repo.repo] = repo }
        for id in clones.keys where byID[id] == nil { byID[id] = RepoInfo(repo: id) }
        return byID.values.filter { !assigned.contains($0.repo) }.map { repo in
            var repo = repo
            repo.clone = clones[repo.repo]
            repo.ignored = ignored.contains(repo.repo)
            return repo
        }.sorted { $0.repo < $1.repo }
    }

    /// The list for the registry as it is now. A hosting that cannot be listed (no login, no
    /// network) is a problem to show, not a reason to show nothing.
    public static func unassigned(registry: Registry = Registry()) async throws -> (repos: [RepoInfo], problems: [String]) {
        var hosted: [RepoInfo] = [], problems: [String] = []
        let spaces = try registry.spaces()
        for space in spaces {
            for hosting in space.hosting {
                do {
                    hosted += try await Repos.hosted(hosting).map { var r = $0; r.space = space.id; return r }
                } catch { problems.append("\(hosting.host)/\(hosting.owner): \(error)") }
            }
        }
        return (unassigned(hosted: hosted, clones: clones(roots: registry.searchRoots),
                           assigned: Set(try registry.assigned().keys), ignored: Set(spaces.flatMap(\.ignore))), problems)
    }
}
