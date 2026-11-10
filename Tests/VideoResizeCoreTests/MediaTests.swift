import XCTest
@testable import VideoResizeCore

/// These tests really encode video, with the encoder the app uses.
final class TranscodeTests: TempDirectoryTestCase {
    func testNativeEncodeKeepsResolutionDurationAndDate() async throws {
        let source = temp.appendingPathComponent("IMG_0001.MOV")
        try await Sample.makeVideo(at: source)
        let info = try await Probe.info(source)
        XCTAssertEqual(info.width, 640)
        XCTAssertEqual(info.height, 360)
        XCTAssertFalse(info.isHEVC)
        XCTAssertTrue(info.hasCaptureDate)
        XCTAssertEqual(info.duration, 2, accuracy: 0.1)

        let destination = temp.appendingPathComponent("out.mov")
        try await NativeTranscoder().transcode(source: source, destination: destination,
                                               info: info, quality: .balanced) { _ in }
        let output = try await Verifier.verify(source: info, output: destination, fullDecode: true)

        XCTAssertTrue(output.isHEVC)
        XCTAssertEqual(output.width, 640)
        XCTAssertEqual(output.height, 360)
        XCTAssertTrue(output.hasCaptureDate)
        XCTAssertLessThan(output.fileSize, info.fileSize)
    }

    func testNativeEncodeCopiesAudio() async throws {
        let silent = temp.appendingPathComponent("silent.mov")
        try await Sample.makeVideo(at: silent)
        let source = temp.appendingPathComponent("with-audio.mov")
        try await Sample.addAudio(to: silent, output: source)
        let info = try await Probe.info(source)
        XCTAssertEqual(info.audioTrackCount, 1)

        let destination = temp.appendingPathComponent("out.mov")
        try await NativeTranscoder().transcode(source: source, destination: destination,
                                               info: info, quality: .balanced) { _ in }
        let output = try await Verifier.verify(source: info, output: destination, fullDecode: true)
        XCTAssertEqual(output.audioTrackCount, 1)
    }

    func testVerifierRejectsAShorterVideo() async throws {
        let long = temp.appendingPathComponent("long.mov")
        try await Sample.makeVideo(at: long, seconds: 4)
        let short = temp.appendingPathComponent("short.mov")
        try await Sample.makeVideo(at: short, seconds: 2)
        let info = try await Probe.info(long)

        let encoded = temp.appendingPathComponent("short-hevc.mov")
        let shortInfo = try await Probe.info(short)
        try await NativeTranscoder().transcode(source: short, destination: encoded,
                                               info: shortInfo, quality: .balanced) { _ in }
        do {
            try await Verifier.verify(source: info, output: encoded, fullDecode: false)
            XCTFail("A shorter video must not pass the check")
        } catch let error as MediaError {
            XCTAssertTrue(error.localizedDescription.contains("duration"), "\(error)")
        }
    }

    func testVerifierRejectsAVideoThatIsNotHEVC() async throws {
        let source = temp.appendingPathComponent("a.mov")
        try await Sample.makeVideo(at: source)
        let info = try await Probe.info(source)
        do {
            try await Verifier.verify(source: info, output: source, fullDecode: false)
            XCTFail("An H.264 video must not pass the check")
        } catch let error as MediaError {
            XCTAssertTrue(error.localizedDescription.contains("HEVC"), "\(error)")
        }
    }
}

final class PipelineTests: TempDirectoryTestCase {
    private var library: FakeLibrary!
    private var store: StateStore!
    private var pipeline: Pipeline!
    private var item: VideoItem!

    private func prepare() async throws {
        let source = temp.appendingPathComponent("library-IMG_0002.MOV")
        try await Sample.makeVideo(at: source)
        let size = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)

        library = FakeLibrary()
        library.add("A", file: source)
        store = StateStore(url: temp.appendingPathComponent("state.json"))
        pipeline = Pipeline(library: library, store: store,
                            workDirectory: temp.appendingPathComponent("work"))
        item = VideoItem(id: "A", filename: "IMG_0002.MOV", creationDate: nil, duration: 2,
                         width: 640, height: 360, fileSize: size)
    }

    func testVideoIsReplacedThenTheOriginalIsDeleted() async throws {
        try await prepare()

        let record = await pipeline.process(item, settings: AppSettings()) { _, _ in }

        XCTAssertEqual(record?.status, .replaced, record?.detail ?? "")
        XCTAssertEqual(record?.newIdentifier, "NEW-A")
        XCTAssertLessThan(record?.newSize ?? .max, record?.originalSize ?? 0)
        XCTAssertEqual(library.imported["NEW-A"], "IMG_0002.MOV")  // same name in Photos
        XCTAssertEqual(library.parked, ["A"])
        XCTAssertTrue(library.exists("A"), "Processing must not delete the original")
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: temp.appendingPathComponent("work").path)
        XCTAssertEqual(leftovers, [], "Temporary files must be removed")

        let result = try await pipeline.deleteOriginals()
        XCTAssertEqual(result.deleted, 1)
        XCTAssertEqual(result.heldBack, 0)
        XCTAssertFalse(library.exists("A"))
        XCTAssertTrue(library.exists("NEW-A"))
        XCTAssertEqual(store.record(for: "A")?.status, .deleted)
    }

    func testOriginalIsKeptWhenTheNewVideoIsMissing() async throws {
        try await prepare()
        await pipeline.process(item, settings: AppSettings()) { _, _ in }
        library.present.remove("NEW-A")  // someone removed the new video

        let result = try await pipeline.deleteOriginals()
        XCTAssertEqual(result.deleted, 0)
        XCTAssertEqual(result.heldBack, 1)
        XCTAssertTrue(library.exists("A"))
        XCTAssertEqual(store.record(for: "A")?.status, .replaced)
    }

    func testSmallSavingKeepsTheOriginal() async throws {
        try await prepare()
        var settings = AppSettings()
        settings.minSavingPercent = 99.9

        let record = await pipeline.process(item, settings: settings) { _, _ in }
        XCTAssertEqual(record?.status, .notWorth)
        XCTAssertTrue(library.imported.isEmpty)
        XCTAssertTrue(library.parked.isEmpty)
    }

    func testImportFailureNeedsReviewAndKeepsTheOriginal() async throws {
        try await prepare()
        library.failImport = true

        let record = await pipeline.process(item, settings: AppSettings()) { _, _ in }
        XCTAssertEqual(record?.status, .needsReview)
        XCTAssertTrue(library.exists("A"))
        XCTAssertTrue(library.parked.isEmpty)
        XCTAssertNotEqual(
            Policy.decide(item: item, record: record, settings: AppSettings(), outputs: []),
            .process, "A half done import must not be retried automatically")
    }

    func testBrokenFileFailsAndCountsTheAttempt() async throws {
        try await prepare()
        let broken = temp.appendingPathComponent("broken.mov")
        try Data(repeating: 7, count: 50_000).write(to: broken)
        library.add("B", file: broken)
        let bad = VideoItem(id: "B", filename: "broken.mov", creationDate: nil, duration: 2,
                            width: 640, height: 360, fileSize: 50_000)

        let first = await pipeline.process(bad, settings: AppSettings()) { _, _ in }
        XCTAssertEqual(first?.status, .failed)
        XCTAssertEqual(first?.attempts, 1)
        let second = await pipeline.process(bad, settings: AppSettings()) { _, _ in }
        XCTAssertEqual(second?.attempts, 2)
        XCTAssertTrue(library.imported.isEmpty)
    }
}
