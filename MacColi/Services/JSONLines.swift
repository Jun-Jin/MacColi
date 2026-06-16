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
}
