import Foundation
import Observation
import PracticesCore

/// One open practice or chain: its code as edited, the parameters, the run in flight and the
/// last result, versions and the history of runs.
@MainActor @Observable
final class PracticeModel {
    let practice: Practice
    let store = PracticeStore()

    var code = "" { didSet { if code != savedCode { dirty = true } } }
    private(set) var savedCode = ""
    private(set) var dirty = false
    private(set) var signature: PracticeSignature?
    var params: [String: String] = [:] { didSet { persistParams() } }

    private(set) var running = false
    private(set) var result: PracticeResult?
    private(set) var failure: String?
    private(set) var versions: [PracticeVersion] = []
    private(set) var runs: [RunRecord] = []
    private(set) var sets: [ParamSet] = []
    /// A step of a chain chosen to look at; nil shows the final result.
    var selectedStep: Int?

    private var runTask: Task<Void, Never>?

    /// Where the project context (environments per source) comes from.
    weak var registry: RegistryModel?

    init(practice: Practice, registry: RegistryModel? = nil) {
        self.practice = practice
        self.registry = registry
        load()
    }

    func load() {
        let text = (try? store.code(of: practice)) ?? ""
        savedCode = text
        code = text
        dirty = false
        params = (UserDefaults.standard.dictionary(forKey: paramsKey) as? [String: String]) ?? [:]
        Task {
            versions = (try? await store.versions(of: practice)) ?? []
            dirty = await store.isDraft(practice) && !versions.isEmpty || text != savedCode
            await refreshSignature()
        }
        runs = (try? RunsStore())?.runs(of: practice.ref) ?? []
        sets = store.sets(of: practice)
    }

    func reloadSets() async { sets = store.sets(of: practice) }

    private var paramsKey: String { "params:" + practice.ref }
    private func persistParams() { UserDefaults.standard.set(params, forKey: paramsKey) }

    func refreshSignature() async {
        signature = try? await PracticeRunner().signature(of: practice)
    }

    /// Saves the code as a new version (a commit of the registry).
    func save() async {
        do {
            try await store.save(code, for: practice)
            savedCode = code
            dirty = false
            versions = (try? await store.versions(of: practice)) ?? []
            await refreshSignature()
        } catch {
            failure = String(describing: error)
        }
    }

    func run() {
        guard !running else { return }
        running = true
        failure = nil
        selectedStep = nil
        runTask = Task {
            do {
                if code != savedCode || dirty {
                    // Unsaved code runs as a draft: written, not committed.
                    try store.writeDraft(code, for: practice)
                    if signature == nil || !(signature?.ok ?? false) { await refreshSignature() }
                }
                result = try await PracticeRunner().run(practice, params: params, envs: registry?.contextEnvs ?? [:])
            } catch is CancellationError {
                failure = String(localized: "Stopped")
            } catch {
                failure = String(describing: error)
            }
            runs = (try? RunsStore())?.runs(of: practice.ref) ?? []
            running = false
        }
    }

    func stop() {
        runTask?.cancel()
    }

    /// Median time per version, newest first, for the versions panel.
    var timings: [(version: Int?, median: Int, count: Int, failed: Int)] {
        let groups = Dictionary(grouping: runs, by: \.version)
        return groups.map { version, runs in
            let ok = runs.filter(\.ok).map(\.millis).sorted()
            let median = ok.isEmpty ? 0 : ok[ok.count / 2]
            return (version, median, runs.count, runs.filter { !$0.ok }.count)
        }
        .sorted { ($0.version ?? .max) > ($1.version ?? .max) }
    }
}
