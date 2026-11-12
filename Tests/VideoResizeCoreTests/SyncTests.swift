import XCTest
@testable import VideoResizeCore

/// iCloud in memory. Two devices share one instance.
final class MemoryStore: SharedStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    var keys: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(values.keys)
    }

    func data(forKey key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func set(_ data: Data, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = data
    }

    func observe(_ handler: @escaping @Sendable ([String]) -> Void) {}
}

/// One device's view of the library: its own local identifiers for the same cloud videos.
struct FakeMapping: IdentifierMapping {
    var localToCloud: [String: String]

    func cloudIdentifiers(for localIdentifiers: [String]) -> [String: String] {
        localToCloud.filter { localIdentifiers.contains($0.key) }
    }

    func localIdentifiers(for cloudIdentifiers: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: localToCloud
            .filter { cloudIdentifiers.contains($0.value) }
            .map { ($0.value, $0.key) })
    }
}

final class RecordSyncTests: TempDirectoryTestCase {
    private let cloud = MemoryStore()

    /// The Mac knows the original as "mac-A" and its new video as "mac-A2";
    /// the iPhone knows the same videos as "phone-A" and "phone-A2".
    private func device(_ name: String, knowsNewVideo: Bool = true) -> (StateStore, RecordSync) {
        var mapping = ["\(name)-A": "cloud-A", "\(name)-B": "cloud-B"]
        if knowsNewVideo { mapping["\(name)-A2"] = "cloud-A2" }
        let store = StateStore(url: temp.appendingPathComponent("\(name).json"))
        return (store, RecordSync(store: store, shared: cloud,
                                  identifiers: FakeMapping(localToCloud: mapping)))
    }

    private func replaced(by newID: String, at date: Date = Date()) -> Record {
        Record(status: .replaced, filename: "IMG_0001.MOV", originalSize: 100, newSize: 40,
               newIdentifier: newID, detail: "Saved 60%", updatedAt: date)
    }

    func testAReplacedVideoReachesTheOtherDeviceWithItsLocalIdentifiers() {
        let (mac, macSync) = device("mac")
        let (phone, phoneSync) = device("phone")
        mac.set(replaced(by: "mac-A2"), for: "mac-A")
        macSync.push()

        XCTAssertTrue(phoneSync.pull())
        let record = phone.record(for: "phone-A")
        XCTAssertEqual(record?.status, .replaced)
        XCTAssertEqual(record?.newIdentifier, "phone-A2")
        XCTAssertNil(phone.record(for: "mac-A"))
        XCTAssertFalse(phoneSync.pull(), "nothing new the second time")
    }

    func testTheNewestRecordWins() {
        let (mac, macSync) = device("mac")
        let (phone, phoneSync) = device("phone")
        let old = Date(timeIntervalSince1970: 1_000_000)
        mac.set(Record(status: .failed, filename: "IMG_0001.MOV", detail: "old", updatedAt: old),
                for: "mac-A")
        phone.set(replaced(by: "phone-A2", at: old.addingTimeInterval(60)), for: "phone-A")
        macSync.push()
        phoneSync.push()

        macSync.pull()
        phoneSync.pull()
        XCTAssertEqual(mac.record(for: "mac-A")?.status, .replaced)
        XCTAssertEqual(mac.record(for: "mac-A")?.newIdentifier, "mac-A2")
        XCTAssertEqual(phone.record(for: "phone-A")?.status, .replaced)
    }

    func testAnImportInWorkIsNeitherSentNorOverwritten() {
        let (mac, macSync) = device("mac")
        let (phone, phoneSync) = device("phone")
        mac.set(Record(status: .importing, filename: "IMG_0001.MOV"), for: "mac-A")
        macSync.push()
        XCTAssertTrue(cloud.keys.isEmpty)

        phone.set(replaced(by: "phone-A2", at: Date().addingTimeInterval(60)), for: "phone-A")
        phoneSync.push()
        macSync.pull()
        XCTAssertEqual(mac.record(for: "mac-A")?.status, .importing)
    }

    func testTheNewVideoIsLinkedOnceItReachesTheDevice() {
        let (mac, macSync) = device("mac")
        let (phone, _) = device("phone", knowsNewVideo: false)
        mac.set(replaced(by: "mac-A2"), for: "mac-A")
        macSync.push()

        // The iPhone sees the record before the new video has synced to it.
        let early = RecordSync(store: phone, shared: cloud, identifiers: FakeMapping(
            localToCloud: ["phone-A": "cloud-A"]))
        early.pull()
        XCTAssertEqual(phone.record(for: "phone-A")?.status, .replaced)
        XCTAssertNil(phone.record(for: "phone-A")?.newIdentifier)

        let later = RecordSync(store: phone, shared: cloud, identifiers: FakeMapping(
            localToCloud: ["phone-A": "cloud-A", "phone-A2": "cloud-A2"]))
        XCTAssertTrue(later.pull())
        XCTAssertEqual(phone.record(for: "phone-A")?.newIdentifier, "phone-A2")
    }

    func testANewVideoNotYetInICloudIsSentLater() {
        let (mac, _) = device("mac")
        let (phone, phoneSync) = device("phone")
        mac.set(replaced(by: "mac-A2"), for: "mac-A")
        // Not uploaded yet: the new video has no cloud identifier.
        RecordSync(store: mac, shared: cloud,
                   identifiers: FakeMapping(localToCloud: ["mac-A": "cloud-A"])).push()
        phoneSync.pull()
        XCTAssertNil(phone.record(for: "phone-A")?.newIdentifier)

        RecordSync(store: mac, shared: cloud, identifiers: FakeMapping(
            localToCloud: ["mac-A": "cloud-A", "mac-A2": "cloud-A2"])).push()
        phoneSync.pull()
        XCTAssertEqual(phone.record(for: "phone-A")?.newIdentifier, "phone-A2")
    }

    func testARecordDroppedByAWriteToTheSameKeyIsPutBack() {
        let map = ShardedMap<Record>(prefix: "records")
        let key = map.key(for: "cloud-A")
        let sameKey = (0...).lazy.map { "cloud-\($0)" }.first { map.key(for: $0) == key }!
        let macIDs = FakeMapping(localToCloud: ["mac-A": "cloud-A", "mac-B": sameKey])
        let phoneIDs = FakeMapping(localToCloud: ["phone-A": "cloud-A", "phone-B": sameKey])
        let mac = StateStore(url: temp.appendingPathComponent("mac.json"))
        let phone = StateStore(url: temp.appendingPathComponent("phone.json"))
        let macSync = RecordSync(store: mac, shared: cloud, identifiers: macIDs)
        let phoneSync = RecordSync(store: phone, shared: cloud, identifiers: phoneIDs)

        // The iPhone writes the key from what it read before the Mac's push.
        let stale = MemoryStore()
        phone.set(Record(status: .notWorth, filename: "IMG_0002.MOV", detail: "small"),
                  for: "phone-B")
        RecordSync(store: phone, shared: stale, identifiers: phoneIDs).push()
        mac.set(replaced(by: "mac-A2"), for: "mac-A")
        macSync.push()
        cloud.set(stale.data(forKey: key)!, forKey: key)
        XCTAssertNil(map.read(key, from: cloud)["cloud-A"], "the Mac's record was dropped")

        // The Mac is told that the key changed: it takes the change in and puts its record back.
        macSync.pull(keys: [key])
        macSync.push()
        XCTAssertEqual(mac.record(for: "mac-B")?.status, .notWorth)
        XCTAssertEqual(map.read(key, from: cloud).count, 2)
        phoneSync.pull()
        XCTAssertEqual(phone.record(for: "phone-A")?.status, .replaced)
    }

    func testACopyIsNotHiddenByADeviceThatWorkedOnTheSameVideo() {
        let (mac, macSync) = device("mac")
        let (phone, phoneSync) = device("phone")
        mac.set(replaced(by: "mac-A2"), for: "mac-A")
        macSync.push()
        // The iPhone finished later, with a saving too small.
        phone.set(Record(status: .notWorth, filename: "IMG_0001.MOV", detail: "small",
                         updatedAt: Date().addingTimeInterval(60)), for: "phone-A")
        phoneSync.pull()
        phoneSync.push()
        macSync.pull()

        XCTAssertEqual(mac.record(for: "mac-A")?.status, .replaced)
        XCTAssertEqual(mac.record(for: "mac-A")?.newIdentifier, "mac-A2")
        XCTAssertEqual(phone.record(for: "phone-A")?.status, .replaced)
        XCTAssertEqual(phone.record(for: "phone-A")?.newIdentifier, "phone-A2")
    }

    func testARestoreReachesTheOtherDevice() {
        let (mac, macSync) = device("mac")
        let (phone, phoneSync) = device("phone")
        let earlier = Date().addingTimeInterval(-600)
        mac.set(replaced(by: "mac-A2", at: earlier), for: "mac-A")
        phone.set(replaced(by: "phone-A2", at: earlier), for: "phone-A")
        macSync.push()
        phone.set(Record(status: .restored, filename: "IMG_0001.MOV", detail: "Restored"),
                  for: "phone-A")
        phoneSync.push()

        macSync.pull()
        XCTAssertEqual(mac.record(for: "mac-A")?.status, .restored)
        XCTAssertNil(mac.record(for: "mac-A")?.newIdentifier)
    }

    func testAPossibleDuplicateStaysFlagged() {
        let (mac, macSync) = device("mac")
        let (phone, phoneSync) = device("phone")
        // The iPhone was stopped while it added the video; the Mac finished it later.
        phone.set(Record(status: .needsReview, filename: "IMG_0001.MOV", newIdentifier: "phone-A2",
                         updatedAt: Date().addingTimeInterval(-600)), for: "phone-A")
        mac.set(replaced(by: "mac-A2"), for: "mac-A")
        macSync.push()
        phoneSync.pull()
        XCTAssertEqual(phone.record(for: "phone-A")?.status, .needsReview)
    }

    func testTheSharedDataStaysWithinTheICloudLimits() {
        let (mac, _) = device("mac")
        var mapping: [String: String] = [:]
        var records: [String: Record] = [:]
        for index in 0..<5000 {
            mapping["mac-\(index)"] = "\(UUID().uuidString)/L0/001"
            records["mac-\(index)"] = Record(status: .notWorth, filename: "IMG_\(index).MOV",
                                             originalSize: 123_456_789, newSize: 98_765_432,
                                             detail: "Saving too small (12%)")
        }
        mac.merge(records)
        RecordSync(store: mac, shared: cloud, identifiers: FakeMapping(localToCloud: mapping)).push()

        XCTAssertLessThanOrEqual(cloud.keys.count, 64)
        let bytes = cloud.keys.reduce(0) { $0 + (cloud.data(forKey: $1)?.count ?? 0) + $1.utf8.count }
        XCTAssertLessThan(bytes, 1_000_000, "the key-value store holds 1 MB in all")
    }
}

final class ImportSyncTests: TempDirectoryTestCase {
    private let cloud = MemoryStore()

    private func entry(_ outcome: ImportOutcome, at date: Date = Date()) -> ImportEntry {
        ImportEntry(outcome: outcome, filename: "C0001.MP4", originalSize: 100, newSize: 40,
                    detail: "", date: date)
    }

    func testACardImportedOnOneDeviceIsKnownOnTheOther() {
        let ipad = ImportLog(url: temp.appendingPathComponent("ipad.json"))
        let phone = ImportLog(url: temp.appendingPathComponent("phone.json"))
        ipad.set(entry(.reencoded), for: "C0001.MP4|100|5")
        ImportSync(log: ipad, shared: cloud).push()

        XCTAssertTrue(ImportSync(log: phone, shared: cloud).pull())
        XCTAssertEqual(phone.entries["C0001.MP4|100|5"]?.outcome, .reencoded)
        let reloaded = ImportLog(url: temp.appendingPathComponent("phone.json"))
        XCTAssertEqual(reloaded.entries["C0001.MP4|100|5"]?.outcome, .reencoded)
    }

    func testEntriesKnowTheDeviceThatImportedThem() {
        let ipad = ImportLog(url: temp.appendingPathComponent("ipad.json"), device: "ipad")
        let phone = ImportLog(url: temp.appendingPathComponent("phone.json"), device: "phone")
        ipad.set(entry(.reencoded), for: "id")
        XCTAssertEqual(ipad.entries["id"]?.device, "ipad")
        ImportSync(log: ipad, shared: cloud).push()

        ImportSync(log: phone, shared: cloud).pull()
        XCTAssertEqual(phone.entries["id"]?.device, "ipad", "a synced entry keeps its device")
    }

    func testACopyWaitingHereIsDroppedOnlyWhenAnotherDeviceImportedItLater() throws {
        let card = temp.appendingPathComponent("C0001.MP4")
        try Data(repeating: 1, count: 1000).write(to: card)
        let video = SourceVideo(url: card, filename: "C0001.MP4", fileSize: 1000, modified: nil)
        let inbox = Inbox(directory: temp.appendingPathComponent("inbox"))
        let log = ImportLog(url: temp.appendingPathComponent("ipad.json"), device: "ipad")

        // Imported long ago on the iPhone, then chosen again on purpose on the iPad.
        log.merge([video.id: ImportEntry(outcome: .reencoded, filename: "C0001.MP4",
                                         originalSize: 1000, newSize: 400, detail: "",
                                         date: Date().addingTimeInterval(-3600), device: "phone")])
        try inbox.add(video)
        XCTAssertFalse(inbox.importedElsewhere(video.id, log: log, device: "ipad"))

        // The iPhone imports it after the iPad copied it.
        log.merge([video.id: ImportEntry(outcome: .reencoded, filename: "C0001.MP4",
                                         originalSize: 1000, newSize: 400, detail: "",
                                         date: Date().addingTimeInterval(60), device: "phone")])
        XCTAssertTrue(inbox.importedElsewhere(video.id, log: log, device: "ipad"))
        XCTAssertFalse(inbox.importedElsewhere(video.id, log: log, device: "phone"),
                       "an import of this same device is not 'elsewhere'")
    }

    func testAFailureNeverHidesAVideoThatIsInPhotos() {
        let ipad = ImportLog(url: temp.appendingPathComponent("ipad.json"))
        let phone = ImportLog(url: temp.appendingPathComponent("phone.json"))
        ipad.set(entry(.original), for: "id")
        phone.set(entry(.failed, at: Date().addingTimeInterval(600)), for: "id")
        ImportSync(log: ipad, shared: cloud).push()
        ImportSync(log: phone, shared: cloud).push()

        ImportSync(log: ipad, shared: cloud).pull()
        ImportSync(log: phone, shared: cloud).pull()
        XCTAssertEqual(ipad.entries["id"]?.outcome, .original)
        XCTAssertEqual(phone.entries["id"]?.outcome, .original)
    }
}
