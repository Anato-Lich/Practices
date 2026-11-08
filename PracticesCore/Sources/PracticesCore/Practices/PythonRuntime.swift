import Foundation

/// The Python environment practices run in: `~/.practices/runtime`, a uv project whose files
/// ship inside PracticesCore. Files are rewritten when they differ from the bundled ones;
/// `uv sync` runs only when the dependencies changed or the venv is missing.
public enum PythonRuntime {

    public static var directory: URL { PracticesHome.url.appendingPathComponent("runtime") }
    public static var python: URL { directory.appendingPathComponent(".venv/bin/python") }

    public struct Failure: Error, CustomStringConvertible, Sendable {
        public let description: String
    }

    static var bundled: URL? { Bundle.module.url(forResource: "python", withExtension: nil) }

    /// Makes the runtime current; returns the interpreter to run practices with.
    @discardableResult
    public static func ensure() async throws -> URL {
        guard let source = bundled else { throw Failure(description: "runtime files missing from the bundle") }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var dependenciesChanged = false
        let files = fm.enumerator(at: source, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for file in files where !file.hasDirectoryPath && !file.lastPathComponent.hasPrefix(".") {
            let relative = file.path.replacingOccurrences(of: source.path + "/", with: "")
            let target = directory.appendingPathComponent(relative)
            let data = try Data(contentsOf: file)
            if (try? Data(contentsOf: target)) != data {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
                if relative == "pyproject.toml" { dependenciesChanged = true }
            }
        }
        if dependenciesChanged || !fm.isExecutableFile(atPath: python.path) {
            guard let uv = uv() else { throw Failure(description: "uv not found: reinstall Practices, it carries uv in Contents/Helpers") }
            _ = try await Shell.run(uv, ["sync", "--project", directory.path, "--quiet"])
        }
        return python
    }

    /// uv (DECISIONS 40): the copy installed beside practicesctl, the running app's, the one in
    /// /Applications, then any on the usual paths.
    public static func uv(home: URL = PracticesHome.url, app: URL = Bundle.main.bundleURL) -> String? {
        let candidates: [String?] = [home.appendingPathComponent("bin/uv").path,
                          app.pathExtension == "app" ? app.appendingPathComponent("Contents/Helpers/uv").path : nil,
                          "/Applications/Practices.app/Contents/Helpers/uv"]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? Shell.locate("uv")
    }
}
