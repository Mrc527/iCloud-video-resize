import Foundation

/// Remembers what happened to each video, in a JSON file.
public final class StateStore: @unchecked Sendable {
    private struct Stored: Codable {
        var records: [String: Record] = [:]
    }

    private let url: URL
    private let lock = NSLock()
    private var stored = Stored()

    public init(url: URL) {
        self.url = url
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode(Stored.self, from: data) {
            stored = decoded
        } else {
            // Never overwrite a file we cannot read: keep it for a person to look at.
            let backup = url.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
        }
    }

    public var records: [String: Record] {
        lock.lock(); defer { lock.unlock() }
        return stored.records
    }

    public func record(for id: String) -> Record? {
        lock.lock(); defer { lock.unlock() }
        return stored.records[id]
    }

    public func set(_ record: Record, for id: String) {
        lock.lock(); defer { lock.unlock() }
        stored.records[id] = record
        save()
    }

    /// Records left in `importing` mean the app stopped during an import.
    /// They are flagged for a person and never retried automatically.
    @discardableResult
    public func recoverInterrupted() -> Int {
        lock.lock(); defer { lock.unlock() }
        var count = 0
        for (id, record) in stored.records where record.status == .importing {
            var updated = record
            updated.status = .needsReview
            updated.detail = "The app stopped during the import"
            stored.records[id] = updated
            count += 1
        }
        if count > 0 { save() }
        return count
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
