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

    func testFFmpegEncodeKeepsCaptureDateAndPosition() async throws {
        guard let ffmpeg = FFmpegTranscoder.locate() else { throw XCTSkip("ffmpeg is not installed") }
        let source = temp.appendingPathComponent("IMG_0003.MOV")
        try await Sample.makeVideo(at: source, location: "+46.0037+008.9511+273.000/")
        let info = try await Probe.info(source)
        XCTAssertTrue(info.hasCaptureDate)
        XCTAssertTrue(info.hasLocation)

        let destination = temp.appendingPathComponent("out.mov")
        try await Reencode.run(FFmpegTranscoder(executable: ffmpeg), source: source,
                               destination: destination, info: info, quality: .balanced) { _ in }
        let output = try await Verifier.verify(source: info, output: destination, original: source,
                                               fullDecode: true)

        XCTAssertTrue(output.isHEVC)
        XCTAssertEqual(output.latitude ?? 0, 46.0037, accuracy: 0.0001)
        XCTAssertEqual(output.longitude ?? 0, 8.9511, accuracy: 0.0001)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.path).sorted(),
                       ["IMG_0003.MOV", "out.mov"], "the intermediate file is left behind")
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

    func testADroneVideoIsReplacedWithAllItsData() async throws {
        try await prepare()
        let source = temp.appendingPathComponent("library-DJI_0001.MOV")
        try await Sample.makeDroneVideo(at: source)
        library.add("D", file: source)
        let size = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let drone = VideoItem(id: "D", filename: "DJI_0001.MOV", creationDate: nil, duration: 2,
                              width: 640, height: 360, fileSize: size)

        let record = await pipeline.process(drone, settings: AppSettings()) { _, _ in }

        XCTAssertEqual(record?.status, .replaced, record?.detail ?? "")
        XCTAssertEqual(library.imported["NEW-D"], "DJI_0001.MOV")
    }

    func testAVideoReplacedOnAnotherDeviceMeanwhileIsNotAddedAgain() async throws {
        try await prepare()
        // Arrived through iCloud while this device was encoding.
        store.set(Record(status: .replaced, filename: "IMG_0002.MOV", newIdentifier: "OTHER"),
                  for: "A")
        let record = await pipeline.process(item, settings: AppSettings()) { _, _ in }

        XCTAssertEqual(record?.status, .replaced)
        XCTAssertEqual(store.record(for: "A")?.newIdentifier, "OTHER")
        XCTAssertTrue(library.imported.isEmpty, "no second copy in Photos")
        XCTAssertTrue(library.parked.isEmpty)
    }

    func testASmallSavingDoesNotHideACopyMadeOnAnotherDevice() async throws {
        try await prepare()
        let other = Record(status: .replaced, filename: "IMG_0002.MOV", newIdentifier: "OTHER")
        store.set(other, for: "A")
        var settings = AppSettings()
        settings.minSavingPercent = 99.9  // this device ends with "not worth it"

        let record = await pipeline.process(item, settings: settings) { _, _ in }

        XCTAssertEqual(record, other)
        XCTAssertEqual(store.record(for: "A"), other)
    }

    func testAFailureDoesNotHideACopyMadeOnAnotherDevice() async throws {
        try await prepare()
        let broken = temp.appendingPathComponent("broken.mov")
        try Data(repeating: 7, count: 50_000).write(to: broken)
        library.add("A", file: broken)
        let other = Record(status: .replaced, filename: "IMG_0002.MOV", newIdentifier: "OTHER")
        store.set(other, for: "A")

        let record = await pipeline.process(item, settings: AppSettings()) { _, _ in }

        XCTAssertEqual(record, other)
        XCTAssertEqual(store.record(for: "A"), other, "no failure, no extra attempt")
    }

    func testARestoreDeletesTheNewVideoAndBringsTheOriginalBack() async throws {
        try await prepare()
        await pipeline.process(item, settings: AppSettings()) { _, _ in }
        XCTAssertEqual(library.parked, ["A"])

        // Chosen from the line of the new video.
        let result = try await pipeline.restore(["NEW-A"])

        XCTAssertEqual(result.restored, 1)
        XCTAssertEqual(result.notHere, 0)
        XCTAssertFalse(library.exists("NEW-A"), "the new video is deleted")
        XCTAssertTrue(library.exists("A"), "the original stays")
        XCTAssertTrue(library.parked.isEmpty, "the original leaves the album")
        let record = try XCTUnwrap(store.record(for: "A"))
        XCTAssertEqual(record.status, .restored)
        XCTAssertNil(record.newIdentifier)
        var settings = AppSettings()
        settings.minSizeMB = 0
        settings.minAgeDays = 0
        settings.minSavingPercent = 0
        XCTAssertEqual(Policy.decide(item: item, record: record, settings: settings, outputs: []),
                       .process, "it can be re-encoded later")
    }

    func testNoRestoreBeforeTheNewVideoIsOnThisDevice() async throws {
        try await prepare()
        // Replaced on another device; the new video has not reached this one yet.
        let record = Record(status: .replaced, filename: "IMG_0002.MOV", newIdentifier: nil)
        store.set(record, for: "A")
        try await library.park(original: "A", albumTitle: Pipeline.albumTitle)

        let result = try await pipeline.restore(["A"])

        XCTAssertEqual(result.restored, 0)
        XCTAssertEqual(result.notHere, 1)
        XCTAssertEqual(store.record(for: "A"), record, "still replaced")
        XCTAssertEqual(library.parked, ["A"], "still waiting in the album")
    }

    func testARestoreAfterThePersonDeletedTheNewVideo() async throws {
        try await prepare()
        await pipeline.process(item, settings: AppSettings()) { _, _ in }
        try await library.delete(["NEW-A"])  // deleted by hand in Photos

        let result = try await pipeline.restore(["A"])

        XCTAssertEqual(result.restored, 1)
        XCTAssertTrue(library.parked.isEmpty, "the original leaves the album")
        XCTAssertEqual(store.record(for: "A")?.status, .restored)
    }

    func testAVideoWithDataAtFixedPlacesIsLeftAsItIs() async throws {
        try await prepare()
        let source = temp.appendingPathComponent("library-NVT_0001.MOV")
        try await Sample.makeVideo(at: source)
        try Sample.editMoov(source) { $0.map(\.bytes) + [Boxes.make("gps ", Data(count: 16))] }
        library.add("G", file: source)
        let size = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let dashcam = VideoItem(id: "G", filename: "NVT_0001.MOV", creationDate: nil, duration: 2,
                                width: 640, height: 360, fileSize: size)

        let record = await pipeline.process(dashcam, settings: AppSettings()) { _, _ in }

        XCTAssertEqual(record?.status, .skipped)
        XCTAssertTrue(record?.detail.contains("could not carry") ?? false, record?.detail ?? "")
        XCTAssertTrue(library.imported.isEmpty)
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
