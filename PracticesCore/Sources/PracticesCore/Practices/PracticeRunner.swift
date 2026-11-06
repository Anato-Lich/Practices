import Foundation

/// What a run returns (`practices_runner.py` writes it; secrets already scrubbed here).
public struct PracticeResult: Codable, Sendable {
    public struct Field: Codable, Hashable, Sendable {
        public let path: String
        public let type: String
        public let present: Int
        public let seen: Int
    }
    public struct Step: Codable, Hashable, Sendable {
        public let ref: String
        public let ok: Bool
        public let ms: Int
        public let error: String?
        public let shape: String?
        public let columns: [String]?
        public let rows: [[JSONValue]]?
        public let tree: JSONValue?
        public let text: String?
        public let total: Int?
        public let bytes: Int?
        public let schema: [Field]?
        public let input: String?
    }
    struct SecretUpdate: Codable, Sendable { let key: String; let value: String }

    public let ok: Bool
    public let error: String?
    public let traceback: String?
    public let ms: Int
    public let shape: String?
    public let columns: [String]?
    public let rows: [[JSONValue]]?
    public let tree: JSONValue?
    public let text: String?
    public let total: Int?
    public let bytes: Int?
    /// SHA-256 of the whole result as canonical JSON: equal digests, equal rows.
    public let digest: String?
    public let schema: [Field]?
    public let steps: [Step]
    var secrets: [SecretUpdate]?

    // Filled on the Swift side.
    public var stdout: String = ""
    public var stderr: String = ""
    public var version: Int?
    public var envs: [String: String] = [:]
    public var secretsUpdated: [String] = []

    enum CodingKeys: String, CodingKey {
        case ok, error, traceback, ms, shape, columns, rows, tree, text, total, bytes, digest, schema, steps, secrets
    }
}

/// A step as kept in the runs history: enough to find the step practice by a field of its
/// output (DECISIONS 24), no data.
public struct StepRecord: Codable, Hashable, Sendable {
    public let ref: String
    public let ok: Bool
    public let ms: Int
    public let rows: Int?
    public let schema: [PracticeResult.Field]?
}

public struct PracticeSignature: Codable, Sendable {
    public struct Param: Codable, Hashable, Sendable {
        public let name: String
        public let annotation: String?
        public let `default`: String?
        public let required: Bool
    }
    public let ok: Bool
    public let error: String?
    public let params: [Param]?
    public let doc: String?
}

/// Runs practices in the Python runtime with the values of the services they touch in their
/// environment (the practice itself reads `os.environ`, like any project would).
public struct PracticeRunner: Sendable {
    public let store: PracticeStore
    public let secrets: SecretStore

    public init(store: PracticeStore = PracticeStore(), secrets: SecretStore = SecretStore()) {
        self.store = store
        self.secrets = secrets
    }

    public struct Failure: Error, CustomStringConvertible, Sendable { public let description: String }

    /// Where the Python side looks practices up: the roots of all spaces.
    var spacesPath: String {
        store.registry.spaceIDs().map { store.registry.dir(ofSpace: $0).path }.joined(separator: ":")
    }

    /// `envs` picks the environment per service; services not named run in their first
    /// environment. Conditions of the services are checked first (DECISIONS 11): a missing
    /// tunnel is a sentence here instead of a timeout inside the practice.
    public func run(_ practice: Practice, params: [String: String], envs: [String: String] = [:]) async throws -> PracticeResult {
        let python = try await PythonRuntime.ensure()
        let refs = store.services(for: practice).map { ServiceRef(service: $0, env: envs[$0]) }
        let resolved = try RunEnvironment.resolve(refs, registry: store.registry, store: secrets)
        var unmet: [String] = []
        for (service, env) in resolved.services {
            unmet += await Checks.unmet(service, env: env, values: try secrets.values(service: service.id, env: env), registry: store.registry)
        }
        if !unmet.isEmpty { throw Failure(description: unmet.joined(separator: "\n")) }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("practices-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let paramsFile = work.appendingPathComponent("params.json")
        let outFile = work.appendingPathComponent("out.json")
        try JSONEncoder().encode(params).write(to: paramsFile)

        var environment = ProcessInfo.processInfo.environment
        for (k, v) in resolved.values { environment[k] = v }
        environment["PRACTICES_SPACES"] = spacesPath
        environment["PYTHONPATH"] = PythonRuntime.directory.path
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"

        let (stdout, stderr) = try await Self.execute(
            python.path, ["-m", "practices_runner", "run", practice.ref, paramsFile.path, outFile.path],
            environment: environment, directory: work)

        // Only values of secret keys are masked: database and user names are ordinary text
        // that results legitimately contain.
        let secretKeys = Set(resolved.services.flatMap { $0.service.keys.filter(\.secret).map(\.name) })
        let secretValues = resolved.values.filter { secretKeys.contains($0.key) }

        guard let raw = try? Data(contentsOf: outFile) else {
            throw Failure(description: "the runner produced no result\n" + scrub(stderr, values: secretValues))
        }
        // Secrets never leave this function: values of the involved services are masked in
        // everything the run produced, before it is decoded.
        let masked = scrub(String(decoding: raw, as: UTF8.self), values: secretValues)
        var result = try JSONDecoder().decode(PracticeResult.self, from: Data(masked.utf8))
        // Rotated values were masked above; take them from the raw result instead.
        let rawResult = try? JSONDecoder().decode(PracticeResult.self, from: raw)
        result.secretsUpdated = try apply(rawResult?.secrets ?? [], services: resolved.services)
        result.secrets = nil
        result.stdout = scrub(stdout, values: secretValues)
        result.stderr = scrub(stderr, values: secretValues)
        result.envs = Dictionary(uniqueKeysWithValues: resolved.services.map { ($0.service.id, $0.env) })
        // A run of unsaved code belongs to no version.
        result.version = await store.isDraft(practice) ? nil : try? await store.versions(of: practice).count
        record(practice, params: params, result: result)
        await FieldsLearner.learn(from: result, practice: practice, registry: store.registry)
        return result
    }

    public func signature(of practice: Practice) async throws -> PracticeSignature {
        let python = try await PythonRuntime.ensure()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("practices-sig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let out = work.appendingPathComponent("sig.json")
        var environment = ProcessInfo.processInfo.environment
        environment["PRACTICES_SPACES"] = spacesPath
        environment["PYTHONPATH"] = PythonRuntime.directory.path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        _ = try await Self.execute(python.path, ["-m", "practices_runner", "signature", practice.ref, out.path],
                                   environment: environment, directory: work)
        return try JSONDecoder().decode(PracticeSignature.self, from: Data(contentsOf: out))
    }

    /// Replaces every value of six characters or more with `***`. Shorter values (ports,
    /// flags) would mask ordinary text and protect nothing.
    func scrub(_ text: String, values: [String: String]) -> String {
        var out = text
        for value in Set(values.values) where value.count >= 6 {
            out = out.replacingOccurrences(of: value, with: "***")
        }
        return out
    }

    /// A practice may hand back a rotated token (`update_secret`): stored for the service that
    /// declares the key, in the environment the run used.
    private func apply(_ updates: [PracticeResult.SecretUpdate], services: [(service: Service, env: String)]) throws -> [String] {
        var done: [String] = []
        for update in updates {
            guard let owner = services.first(where: { $0.service.keys.contains { $0.name == update.key } }) else { continue }
            try secrets.set(update.value, key: update.key, service: owner.service.id, env: owner.env)
            done.append(update.key)
        }
        return done
    }

    private func record(_ practice: Practice, params: [String: String], result: PracticeResult) {
        guard let runs = try? RunsStore() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let schema = result.schema.flatMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        let steps = result.steps.map { StepRecord(ref: $0.ref, ok: $0.ok, ms: $0.ms, rows: $0.total, schema: $0.schema) }
        let stepsJSON = (try? encoder.encode(steps)).map { String(decoding: $0, as: UTF8.self) }
        let paramsJSON = (try? encoder.encode(params)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let env = result.envs.sorted { $0.key < $1.key }.map { "\($0.key)@\($0.value)" }.joined(separator: " ")
        _ = try? runs.insert(ref: practice.ref, version: result.version, env: env, params: paramsJSON,
                             started: Date().addingTimeInterval(-Double(result.ms) / 1000), millis: result.ms,
                             ok: result.ok, rows: result.total, bytes: result.bytes, error: result.error,
                             schema: schema, steps: stepsJSON)
    }

    /// Runs a process to completion; cancelling the calling task terminates it.
    static func execute(_ path: String, _ args: [String], environment: [String: String],
                        directory: URL) async throws -> (String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.environment = environment
        process.currentDirectoryURL = directory
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let collector = OutputCollector()
        out.fileHandleForReading.readabilityHandler = { collector.append(out: $0.availableData) }
        err.fileHandleForReading.readabilityHandler = { collector.append(err: $0.availableData) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(String, String), Error>) in
                process.terminationHandler = { _ in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    collector.append(out: out.fileHandleForReading.readDataToEndOfFile())
                    collector.append(err: err.fileHandleForReading.readDataToEndOfFile())
                    continuation.resume(returning: collector.strings)
                }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
