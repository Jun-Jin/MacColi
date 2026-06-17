import Foundation

/// Decodes newline-delimited JSON (one JSON object per line), as emitted by
/// `docker --format '{{json .}}'` and `colima list --json`.
enum JSONLines {
    static func decode<T: Decodable>(_ type: T.Type, from text: String) -> [T] {
        let decoder = JSONDecoder()
        var results: [T] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            if let value = try? decoder.decode(T.self, from: data) {
                results.append(value)
            }
        }
        return results
    }
}

enum Format {
    /// Bytes → "8 GB" style string.
    static func bytes(_ value: Int64?) -> String {
        guard let value, value > 0 else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: value)
    }

    /// Parses a docker-formatted size ("233.6MiB", "1.5GB", "12kB") to bytes.
    /// Handles both binary (KiB/MiB/GiB) and decimal (kB/MB/GB) suffixes docker
    /// emits across `stats`/`df`. Longer suffixes are matched first so "MiB"
    /// never resolves as a bare "B".
    static func parseBytes(_ text: String) -> Int64? {
        let t = text.trimmingCharacters(in: .whitespaces)
        let units: [(String, Double)] = [
            ("TiB", 1_099_511_627_776), ("GiB", 1_073_741_824), ("MiB", 1_048_576), ("KiB", 1_024),
            ("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("B", 1)
        ]
        for (suffix, mult) in units where t.hasSuffix(suffix) {
            let num = t.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            return Double(num).map { Int64($0 * mult) }
        }
        return Double(t).map { Int64($0) }
    }

    /// Parses a docker percentage ("3.80%") to a Double (3.80).
    static func parsePercent(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: ""))
    }
}
