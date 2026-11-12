import Foundation

/// Key-value storage shared by the devices of one iCloud account. The tests use a fake one.
public protocol SharedStore: AnyObject, Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
    /// `handler` gets the keys that another device changed. Called on any thread.
    func observe(_ handler: @escaping @Sendable ([String]) -> Void)
}

/// The iCloud key-value store. The Mac app and the iPad/iPhone app use the same store
/// identifier in their entitlements, so they see the same data.
public final class ICloudStore: SharedStore, @unchecked Sendable {
    private let store = NSUbiquitousKeyValueStore.default
    private let lock = NSLock()
    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// nil for a build without the iCloud entitlement: its writes would go nowhere.
    public static func make() -> ICloudStore? {
        let candidate = ICloudStore()
        return candidate.store.synchronize() ? candidate : nil
    }

    public func data(forKey key: String) -> Data? {
        store.data(forKey: key)
    }

    public func set(_ data: Data, forKey key: String) {
        store.set(data, forKey: key)
    }

    public func observe(_ handler: @escaping @Sendable ([String]) -> Void) {
        let token = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store, queue: nil
        ) { note in
            handler(note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? [])
        }
        lock.lock(); defer { lock.unlock() }
        observers.append(token)
    }
}

/// A dictionary split over a fixed set of keys, compressed: the iCloud key-value
/// store allows at most 1024 keys and 1 MB in all.
struct ShardedMap<Value: Codable> {
    static var shardCount: Int { 64 }
    let prefix: String

    func key(for id: String) -> String {
        // FNV-1a: the same on every device and at every launch, unlike hashValue.
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return key(shard: Int(hash % UInt32(Self.shardCount)))
    }

    var allKeys: [String] { (0..<Self.shardCount).map(key(shard:)) }

    func owns(_ key: String) -> Bool { key.hasPrefix(prefix + ".") }

    private func key(shard: Int) -> String { prefix + "." + String(format: "%02x", shard) }

    func read(_ key: String, from store: SharedStore) -> [String: Value] {
        guard let packed = store.data(forKey: key),
              let json = try? (packed as NSData).decompressed(using: .lzfse) as Data,
              let entries = try? Self.decoder.decode([String: Value].self, from: json)
        else { return [:] }
        return entries
    }

    func write(_ entries: [String: Value], to key: String, in store: SharedStore) {
        guard let json = try? Self.encoder.encode(entries),
              let packed = try? (json as NSData).compressed(using: .lzfse) as Data
        else { return }
        store.set(packed, forKey: key)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

/// The local state files keep whole seconds only, so dates are compared in seconds.
private func seconds(_ date: Date) -> Double {
    date.timeIntervalSince1970.rounded(.down)
}

// MARK: - Photos library records

/// PhotoKit identifiers differ from device to device. The cloud identifier is the same
/// everywhere, for the videos that are in iCloud Photos.
public protocol IdentifierMapping: Sendable {
    /// Local identifier -> cloud identifier, for the ones that have one.
    func cloudIdentifiers(for localIdentifiers: [String]) -> [String: String]
    /// Cloud identifier -> local identifier, for the videos on this device.
    func localIdentifiers(for cloudIdentifiers: [String]) -> [String: String]
}

/// Shares the records of the Photos library with the other devices of the iCloud account.
///
/// Each device keeps its own state file. The shared copy is keyed by the cloud identifier
/// of the original video, and the newest record wins. A video being added to Photos is
/// never shared: the other devices see it once it is done.
public final class RecordSync: @unchecked Sendable {
    private let store: StateStore
    private let shared: SharedStore
    private let identifiers: IdentifierMapping
    private let map = ShardedMap<Record>(prefix: "records")
    private let lock = NSLock()

    public init(store: StateStore, shared: SharedStore, identifiers: IdentifierMapping) {
        self.store = store
        self.shared = shared
        self.identifiers = identifiers
    }

    /// Take in what the other devices did. `keys` limits the work to the changed keys.
    /// Returns true when a local record changed.
    @discardableResult
    public func pull(keys: [String]? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var remote: [String: Record] = [:]
        for key in keys?.filter(map.owns) ?? map.allKeys {
            remote.merge(map.read(key, from: shared)) { $1 }
        }
        guard !remote.isEmpty else { return false }
        let local = identifiers.localIdentifiers(
            for: Array(Set(remote.keys).union(remote.values.compactMap(\.newIdentifier))))

        var updates: [String: Record] = [:]
        for (cloudID, record) in remote where record.status != .importing {
            guard let id = local[cloudID] else { continue }  // not on this device, or not yet
            let current = store.record(for: id)
            var incoming = record
            // The new video may not have reached this device yet.
            incoming.newIdentifier = record.newIdentifier.flatMap { local[$0] }
                ?? (record.newIdentifier == nil ? nil : current?.newIdentifier)
            if Self.replaces(incoming, current) { updates[id] = incoming }
        }
        store.merge(updates)
        return !updates.isEmpty
    }

    /// Send the local records to the other devices.
    public func push() {
        lock.lock(); defer { lock.unlock() }
        let records = store.records.filter { $0.value.status != .importing }
        guard !records.isEmpty else { return }
        let cloud = identifiers.cloudIdentifiers(
            for: Array(Set(records.keys).union(records.values.compactMap(\.newIdentifier))))

        var outgoing: [String: [String: Record]] = [:]  // by shard key
        for (id, record) in records {
            guard let cloudID = cloud[id] else { continue }  // not in iCloud Photos (yet)
            outgoing[map.key(for: cloudID), default: [:]][cloudID] = record
        }
        for (key, records) in outgoing {
            var entries = map.read(key, from: shared)
            var changed = false
            for (cloudID, record) in records {
                var record = record
                // The new video may not be uploaded yet: keep what the shared copy knows.
                record.newIdentifier = record.newIdentifier.flatMap { cloud[$0] }
                    ?? (record.newIdentifier == nil ? nil : entries[cloudID]?.newIdentifier)
                if Self.replaces(record, entries[cloudID]) {
                    entries[cloudID] = record
                    changed = true
                }
            }
            if changed { map.write(entries, to: key, in: shared) }
        }
    }

    /// `incoming` wins when it is newer, or as new and it knows the new video.
    static func replaces(_ incoming: Record, _ current: Record?) -> Bool {
        guard let current else { return true }
        if current.status == .importing { return false }  // in work on this device
        // This device stopped during an import: its possible duplicate stays flagged.
        if current.status == .needsReview { return false }
        let (new, old) = (seconds(incoming.updatedAt), seconds(current.updatedAt))
        // A restore is a person's decision: only the time decides.
        if incoming.status == .restored || current.status == .restored {
            return new > old
        }
        // The record that knows a copy in Photos wins: another device may have worked on
        // the same video at the same time.
        if current.status.hasNewVideo && !incoming.status.hasNewVideo { return false }
        if incoming.status.hasNewVideo && !current.status.hasNewVideo { return true }
        if new != old { return new > old }
        return current.newIdentifier == nil && incoming.newIdentifier != nil
    }
}

// MARK: - SD card imports

/// Shares the list of imported card files, so that another device does not select them
/// again. The file identifiers are the same on every device.
public final class ImportSync: @unchecked Sendable {
    private let log: ImportLog
    private let shared: SharedStore
    private let map = ShardedMap<ImportEntry>(prefix: "imports")
    private let lock = NSLock()

    public init(log: ImportLog, shared: SharedStore) {
        self.log = log
        self.shared = shared
    }

    /// Returns true when a local entry changed.
    @discardableResult
    public func pull(keys: [String]? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let local = log.entries
        var updates: [String: ImportEntry] = [:]
        for key in keys?.filter(map.owns) ?? map.allKeys {
            for (id, entry) in map.read(key, from: shared) where Self.replaces(entry, local[id]) {
                updates[id] = entry
            }
        }
        log.merge(updates)
        return !updates.isEmpty
    }

    public func push() {
        lock.lock(); defer { lock.unlock() }
        var outgoing: [String: [String: ImportEntry]] = [:]
        for (id, entry) in log.entries {
            outgoing[map.key(for: id), default: [:]][id] = entry
        }
        for (key, entries) in outgoing {
            var shared = map.read(key, from: self.shared)
            var changed = false
            for (id, entry) in entries where Self.replaces(entry, shared[id]) {
                shared[id] = entry
                changed = true
            }
            if changed { map.write(shared, to: key, in: self.shared) }
        }
    }

    /// The newest entry wins, but a failure never hides a video that is in Photos.
    static func replaces(_ incoming: ImportEntry, _ current: ImportEntry?) -> Bool {
        guard let current else { return true }
        if incoming.outcome == .failed && current.outcome != .failed { return false }
        if current.outcome == .failed && incoming.outcome != .failed { return true }
        return seconds(incoming.date) > seconds(current.date)
    }
}
