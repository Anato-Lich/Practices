import Foundation

/// Finds which of many byte strings occur in a file, in one pass over its bytes: a 64K-bit
/// table of two-byte prefixes rejects almost every position, a four-byte prefix map narrows
/// the rest, and only then are whole values compared. Built for Doctor's search of ~/Projects
/// (tens of thousands of files, a few dozen secrets), where `grep -F` took minutes.
struct MultiSearch: Sendable {
    private let needles: [[UInt8]]
    private let first2: [UInt64]              // bitmap over UInt16 prefixes
    private let first4: [UInt32: [Int]]       // prefix → needle indices

    /// Needles shorter than four bytes are ignored: too short to mean anything as a secret.
    init(_ values: [String]) {
        var needles: [[UInt8]] = []
        var first2 = [UInt64](repeating: 0, count: 65536 / 64)
        var first4: [UInt32: [Int]] = [:]
        for value in values {
            let bytes = Array(value.utf8)
            guard bytes.count >= 4 else { continue }
            let i = needles.count
            needles.append(bytes)
            let p2 = Int(UInt16(bytes[0]) | UInt16(bytes[1]) << 8)
            first2[p2 >> 6] |= 1 << UInt64(p2 & 63)
            let p4 = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            first4[p4, default: []].append(i)
        }
        self.needles = needles
        self.first2 = first2
        self.first4 = first4
    }

    /// Indices (into the values given to `init`, counting only the kept ones) found in `data`.
    func matches(in data: Data) -> Set<Int> {
        guard !needles.isEmpty else { return [] }
        var found = Set<Int>()
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count >= 4 else { return }
            let count = raw.count
            var i = 0
            while i <= count - 4 {
                let p2 = Int(UInt16(base[i]) | UInt16(base[i + 1]) << 8)
                if first2[p2 >> 6] & (1 << UInt64(p2 & 63)) != 0 {
                    let p4 = UInt32(base[i]) | UInt32(base[i + 1]) << 8 | UInt32(base[i + 2]) << 16 | UInt32(base[i + 3]) << 24
                    if let candidates = first4[p4] {
                        for n in candidates where !found.contains(n) {
                            let needle = needles[n]
                            if i + needle.count <= count,
                               needle.withUnsafeBufferPointer({ memcmp(base + i, $0.baseAddress!, needle.count) == 0 }) {
                                found.insert(n)
                            }
                        }
                    }
                }
                i += 1
            }
        }
        return found
    }

    /// Scans files concurrently; returns path → indices of the needles found in it.
    func scan(_ paths: [String], workers: Int = ProcessInfo.processInfo.activeProcessorCount) async -> [String: Set<Int>] {
        await withTaskGroup(of: [String: Set<Int>].self) { group in
            let chunk = max(1, (paths.count + workers - 1) / workers)
            for start in stride(from: 0, to: paths.count, by: chunk) {
                let slice = paths[start..<min(start + chunk, paths.count)]
                group.addTask {
                    var out: [String: Set<Int>] = [:]
                    for path in slice {
                        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { continue }
                        let hits = matches(in: data)
                        if !hits.isEmpty { out[path] = hits }
                    }
                    return out
                }
            }
            var all: [String: Set<Int>] = [:]
            for await part in group { all.merge(part) { a, _ in a } }
            return all
        }
    }
}
