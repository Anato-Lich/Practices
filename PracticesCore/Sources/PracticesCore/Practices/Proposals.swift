import Foundation

/// A change to a practice sent from a project (DECISIONS 21): the code, what and why, and the
/// parameters the agent tried it on. Kept in `~/.practices/proposals/<id>.json`.
public struct Proposal: Codable, Identifiable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case pending, accepted, rejected }

    public struct Check: Codable, Hashable, Sendable {
        public let name: String          // "set: three devices", "agent's parameters", "schema"
        public let ok: Bool
        public let detail: String
    }

    public let id: String
    public let ref: String
    public let created: Date
    /// Where it came from: the project path the agent works in, or "manual".
    public let origin: String
    public let why: String
    public let code: String
    public let params: [String: String]?
    /// Version the change was made against; a newer one arriving since is a conflict.
    public let baseVersion: Int
    public var status: Status
    public var checks: [Check]
    /// Why it was or was not accepted automatically.
    public var verdict: String
    public var acceptedVersion: Int?
    public var decidedBy: String?        // "auto" | "user"
    public var decided: Date?
}

public struct ProposalStore: Sendable {
    public let dir: URL

    public init(dir: URL = PracticesHome.url.appendingPathComponent("proposals")) { self.dir = dir }

    public func all() -> [Proposal] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Proposal.self, from: Data(contentsOf: $0)) }
            .sorted { $0.created > $1.created }
    }

    public func pending() -> [Proposal] { all().filter { $0.status == .pending } }

    public func save(_ proposal: Proposal) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(proposal).write(to: dir.appendingPathComponent("\(proposal.id).json"), options: .atomic)
    }
}

/// Checks a proposal against the current version and applies the auto-accept rules
/// (DECISIONS 22): same result shape, same rows on the saved sets, not slower by more than
/// 5%, the source not marked as writable. Anything else waits for the user, with the reason.
public struct ProposalReviewer: Sendable {
    public let store: PracticeStore
    public let runner: PracticeRunner
    public let proposals: ProposalStore
    public static let slowerTolerance = 1.05
    /// Fast queries jitter by tens of milliseconds over a tunnel: under this, time is not judged.
    public static let slowerSlackMillis = 50

    public init(store: PracticeStore = PracticeStore(), proposals: ProposalStore = ProposalStore()) {
        self.store = store
        self.runner = PracticeRunner(store: store)
        self.proposals = proposals
    }

    /// Records the proposal, checks it, accepts it when every rule holds.
    public func submit(ref: String, code: String, why: String, params: [String: String]?, origin: String) async throws -> Proposal {
        let practice = Practice(ref: ref)
        let versions = try await store.versions(of: practice)
        var proposal = Proposal(
            id: ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "") + "-" + String(UUID().uuidString.prefix(6)),
            ref: ref, created: Date(), origin: origin, why: why, code: code, params: params,
            baseVersion: versions.count, status: .pending, checks: [], verdict: "")
        let (checks, verdict, acceptable) = await check(proposal, existing: !versions.isEmpty)
        proposal.checks = checks
        proposal.verdict = verdict
        try proposals.save(proposal)
        if acceptable { proposal = try await accept(proposal, by: "auto") }
        return proposal
    }

    public func accept(_ proposal: Proposal, by: String) async throws -> Proposal {
        var p = proposal
        let practice = Practice(ref: p.ref)
        let firstLine = p.why.split(separator: "\n").first.map(String.init) ?? ""
        let version = try await store.save(p.code, for: practice, message: "\(by == "auto" ? "auto-accepted" : "accepted") from \(p.origin) — \(firstLine)")
        // The agent's parameters join the saved sets, so the next change is checked on them too.
        if let params = p.params, !params.isEmpty {
            let project = (p.origin as NSString).lastPathComponent
            let when = p.created.formatted(.dateTime.day(.twoDigits).month(.twoDigits).hour().minute())
            try? await store.saveSet(ParamSet(name: "agent · \(project) · \(when)", params: params), for: practice)
        }
        p.status = .accepted
        if let version { p.acceptedVersion = version } else { p.acceptedVersion = try await store.versions(of: practice).count }
        p.decidedBy = by
        p.decided = Date()
        try proposals.save(p)
        return p
    }

    public func reject(_ proposal: Proposal) throws -> Proposal {
        var p = proposal
        p.status = .rejected
        p.decidedBy = "user"
        p.decided = Date()
        try proposals.save(p)
        return p
    }

    func check(_ proposal: Proposal, existing: Bool) async -> (checks: [Proposal.Check], verdict: String, acceptable: Bool) {
        let practice = Practice(ref: proposal.ref)
        var checks: [Proposal.Check] = []
        var reasons: [String] = []

        if let source = practice.source, let s = try? store.registry.source(source), s.tags.contains("write-allowed") {
            checks.append(.init(name: "source", ok: false, detail: "\(source) is marked write-allowed"))
            reasons.append("the source allows writes")
        }
        guard existing else {
            return ([.init(name: "new practice", ok: false, detail: "nothing to compare with")], "a new practice is always reviewed", false)
        }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("practices-proposal-\(proposal.id)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let file = work.appendingPathComponent("\(practice.name).py")
        try? proposal.code.write(to: file, atomically: true, encoding: .utf8)
        let overrides = [proposal.ref: file]

        var sets = store.sets(of: practice)
        if let params = proposal.params { sets.append(ParamSet(name: "agent's parameters", params: params)) }
        if sets.isEmpty {
            checks.append(.init(name: "parameters", ok: false, detail: "no saved sets and none sent: nothing to run on"))
            return (checks, "cannot be checked without parameters", false)
        }

        var comparedRows = false
        for set in sets {
            // Two runs each, alternating, the faster of each kept: one run is too noisy to judge 5%.
            var old: [PracticeResult] = [], new: [PracticeResult] = []
            for _ in 0..<2 {
                if let r = try? await runner.run(practice, params: set.params, overrides: [:], record: false) { old.append(r) }
                if let r = try? await runner.run(practice, params: set.params, overrides: overrides) { new.append(r) }
            }
            let oldBest = old.filter(\.ok).min { $0.ms < $1.ms }
            let newBest = new.filter(\.ok).min { $0.ms < $1.ms }
            let isAgentSet = set.name == "agent's parameters"
            guard let n = newBest else {
                let error = new.first?.error ?? "did not run"
                checks.append(.init(name: set.name, ok: false, detail: "new version fails: \(error)"))
                reasons.append("fails on \(set.name)")
                continue
            }
            guard let o = oldBest else {
                // The old version failing where the new one works is the point of many fixes.
                checks.append(.init(name: set.name, ok: true, detail: "old version fails, new runs in \(n.ms) ms"))
                if !isAgentSet { reasons.append("old version fails on a saved set — review the change") }
                continue
            }
            let sameSchema = Set((o.schema ?? []).map { "\($0.path):\($0.type)" }) == Set((n.schema ?? []).map { "\($0.path):\($0.type)" })
            let sameRows = o.digest != nil && o.digest == n.digest
            let faster = Double(n.ms) <= Double(o.ms) * Self.slowerTolerance || n.ms - o.ms <= Self.slowerSlackMillis
            comparedRows = comparedRows || sameRows
            checks.append(.init(name: set.name, ok: sameSchema && sameRows && faster,
                                detail: "\(sameRows ? "same rows" : "rows differ"), \(sameSchema ? "same fields" : "fields differ"), \(o.ms) → \(n.ms) ms"))
            if !sameSchema { reasons.append("fields differ on \(set.name)") }
            if !sameRows { reasons.append("rows differ on \(set.name)") }
            if !faster {
                let pct = Int((Double(n.ms) / Double(max(o.ms, 1)) - 1) * 100)
                reasons.append("slower by \(pct)% on \(set.name) (tolerance 5%, or 50 ms)")
            }
        }
        if !comparedRows && reasons.isEmpty { reasons.append("no set where both versions ran to compare rows") }
        let acceptable = reasons.isEmpty
        return (checks, acceptable ? "every rule holds" : reasons.joined(separator: "; "), acceptable)
    }
}
