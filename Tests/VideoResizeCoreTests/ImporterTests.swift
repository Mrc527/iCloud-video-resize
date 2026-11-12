import XCTest
@testable import VideoResizeCore

final class FakeSink: PhotoSink, @unchecked Sendable {
    struct Added {
        let name: String
        let size: Int64
        let date: Date?
        var latitude: Double?
        var longitude: Double?
    }
    var added: [Added] = []
    var fail = false

    func add(file: URL, creationDate: Date?, latitude: Double?,
             longitude: Double?) async throws -> String {
        if fail { throw LibraryError.importFailed }
        let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        added.append(Added(name: file.lastPathComponent, size: size, date: creationDate,
                           latitude: latitude, longitude: longitude))
        return "ID-\(added.count)"
    }
}

final class ISO6709Tests: XCTestCase {
    func testPositionWithAltitude() {
        let place = ISO6709.parse("+45.4642+009.1900+120.000/")
        XCTAssertEqual(place?.latitude ?? 0, 45.4642, accuracy: 0.0001)
        XCTAssertEqual(place?.longitude ?? 0, 9.19, accuracy: 0.0001)
    }

    func testSouthWestWithoutAltitude() {
        let place = ISO6709.parse("-33.8688-151.2093/")
        XCTAssertEqual(place?.latitude ?? 0, -33.8688, accuracy: 0.0001)
        XCTAssertEqual(place?.longitude ?? 0, -151.2093, accuracy: 0.0001)
    }

    func testRubbishIsRejected() {
        XCTAssertNil(ISO6709.parse(""))
        XCTAssertNil(ISO6709.parse("Milan"))
        XCTAssertNil(ISO6709.parse("+999.0+009.0/"))
    }
}

final class ScannerTests: TempDirectoryTestCase {
    func testFindsVideosInSubfoldersAndReportsUnsupportedOnes() throws {
        let clips = temp.appendingPathComponent("DCIM/100GOPRO")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        for name in ["GX010001.MP4", "GX010001.LRV", "GX010001.THM", "C0001.mov",
                     "00001.MTS", ".hidden.mp4", "notes.txt"] {
            try Data(count: 10).write(to: clips.appendingPathComponent(name))
        }

        let result = SourceScanner.scan(folder: temp)
        XCTAssertEqual(Set(result.videos.map(\.filename)), ["GX010001.MP4", "C0001.mov"])
        XCTAssertEqual(result.unsupported, ["00001.MTS"])
        XCTAssertEqual(result.videos.first?.fileSize, 10)
    }

    func testSameFileHasTheSameIdentifier() throws {
        try Data(count: 10).write(to: temp.appendingPathComponent("a.mp4"))
        let first = SourceScanner.scan(folder: temp).videos.first
        let second = SourceScanner.scan(folder: temp).videos.first
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.id, second?.id)
    }
}

final class ImporterTests: TempDirectoryTestCase {
    private var sink: FakeSink!
    private var log: ImportLog!
    private var importer: Importer!
    private var card: URL!

    private func prepare() async throws -> SourceVideo {
        card = temp.appendingPathComponent("card")
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        try await Sample.makeVideo(at: card.appendingPathComponent("C0001.MP4"))

        sink = FakeSink()
        log = ImportLog(url: temp.appendingPathComponent("log.json"))
        importer = Importer(sink: sink, log: log,
                            workDirectory: temp.appendingPathComponent("work"))
        return try XCTUnwrap(SourceScanner.scan(folder: card).videos.first)
    }

    func testVideoIsReencodedAndTheCardIsNotChanged() async throws {
        let video = try await prepare()

        let entry = await importer.importVideo(video, settings: AppSettings()) { _, _ in }

        XCTAssertEqual(entry?.outcome, .reencoded, entry?.detail ?? "")
        XCTAssertEqual(sink.added.count, 1)
        XCTAssertEqual(sink.added.first?.name, "C0001.MP4", "same name and type as on the card")
        XCTAssertLessThan(sink.added.first?.size ?? .max, video.fileSize)
        XCTAssertLessThan(entry?.newSize ?? .max, entry?.originalSize ?? 0)

        // The capture date comes from the file, not from today.
        let expected = ISO8601DateFormatter().date(from: "2020-01-01T09:00:00Z")!
        let date = try XCTUnwrap(sink.added.first?.date)
        XCTAssertEqual(date.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 2)

        XCTAssertEqual(SourceScanner.scan(folder: card).videos.first, video,
                       "The file on the card must not change")
        XCTAssertEqual(ImportLog(url: temp.appendingPathComponent("log.json")).entries[video.id]?
            .outcome, .reencoded, "The import must be remembered")
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: temp.appendingPathComponent("work").path)
        XCTAssertEqual(leftovers, [], "Temporary files must be removed")
    }

    func testCompactVideoIsAddedAsItIs() async throws {
        let video = try await prepare()
        var settings = AppSettings()
        settings.minSavingPercent = 99.9

        let entry = await importer.importVideo(video, settings: settings) { _, _ in }

        XCTAssertEqual(entry?.outcome, .original)
        XCTAssertEqual(sink.added.first?.name, "C0001.MP4")
        XCTAssertEqual(sink.added.first?.size, video.fileSize)
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.url.path))
    }

    func testADroneVideoIsReencodedWithAllItsDataAndPosition() async throws {
        _ = try await prepare()
        let url = card.appendingPathComponent("DJI_0001.MOV")
        try await Sample.makeDroneVideo(at: url)
        let video = try XCTUnwrap(SourceScanner.scan(folder: card).videos
            .first { $0.filename == "DJI_0001.MOV" })

        let entry = await importer.importVideo(video, settings: AppSettings()) { _, _ in }

        XCTAssertEqual(entry?.outcome, .reencoded, entry?.detail ?? "")
        XCTAssertEqual(sink.added.first?.name, "DJI_0001.MOV")
        // Apple's frameworks cannot read ©xyz: the position is read from the user data.
        XCTAssertEqual(sink.added.first?.latitude ?? 0, 46.0037, accuracy: 0.0001)
        XCTAssertEqual(sink.added.first?.longitude ?? 0, 8.9511, accuracy: 0.0001)
    }

    func testBrokenFileIsNotAdded() async throws {
        _ = try await prepare()
        let url = card.appendingPathComponent("broken.mp4")
        try Data(repeating: 7, count: 50_000).write(to: url)
        let broken = SourceVideo(url: url, filename: "broken.mp4", fileSize: 50_000, modified: nil)

        let entry = await importer.importVideo(broken, settings: AppSettings()) { _, _ in }
        XCTAssertEqual(entry?.outcome, .failed)
        XCTAssertTrue(sink.added.isEmpty)
    }

    func testPhotosErrorIsAFailure() async throws {
        let video = try await prepare()
        sink.fail = true

        let entry = await importer.importVideo(video, settings: AppSettings()) { _, _ in }
        XCTAssertEqual(entry?.outcome, .failed)
        XCTAssertEqual(log.entries[video.id]?.outcome, .failed)
    }
}

final class InboxTests: TempDirectoryTestCase {
    private func makeCardFile() throws -> SourceVideo {
        let card = temp.appendingPathComponent("card")
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1234).write(to: card.appendingPathComponent("C0001.MP4"))
        return try XCTUnwrap(SourceScanner.scan(folder: card).videos.first)
    }

    func testCopyDoesNotNeedTheCardAnymore() throws {
        let video = try makeCardFile()
        let inbox = Inbox(directory: temp.appendingPathComponent("inbox"))
        try inbox.add(video)
        try inbox.add(video)  // a second time changes nothing

        XCTAssertTrue(inbox.contains(video.id))
        XCTAssertEqual(inbox.totalBytes, 1234)
        let local = try XCTUnwrap(inbox.pending.first)
        XCTAssertEqual(inbox.pending.count, 1)
        XCTAssertEqual(local.id, video.id, "The copy must be recognised as the same video")
        XCTAssertNotEqual(local.url, video.url)

        // The card is removed: the copy is still readable.
        try FileManager.default.removeItem(at: temp.appendingPathComponent("card"))
        XCTAssertEqual(try Data(contentsOf: local.url).count, 1234)
    }

    func testWaitingVideosSurviveARestart() throws {
        let video = try makeCardFile()
        let directory = temp.appendingPathComponent("inbox")
        try Inbox(directory: directory).add(video)

        let reopened = Inbox(directory: directory)
        XCTAssertEqual(reopened.pending.map(\.id), [video.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.pending[0].url.path))
    }

    func testRemoveDeletesTheCopyButNotTheCardFile() throws {
        let video = try makeCardFile()
        let directory = temp.appendingPathComponent("inbox")
        let inbox = Inbox(directory: directory)
        try inbox.add(video)
        let local = try XCTUnwrap(inbox.pending.first)

        inbox.remove(video.id)
        XCTAssertTrue(inbox.pending.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.url.path))
        XCTAssertTrue(Inbox(directory: directory).pending.isEmpty)
    }

    func testFailedCopyLeavesNothingBehind() throws {
        let missing = SourceVideo(url: temp.appendingPathComponent("gone.mp4"),
                                  filename: "gone.mp4", fileSize: 10, modified: nil)
        let directory = temp.appendingPathComponent("inbox")
        let inbox = Inbox(directory: directory)
        XCTAssertThrowsError(try inbox.add(missing))
        XCTAssertTrue(inbox.pending.isEmpty)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(left, [])
    }
}
