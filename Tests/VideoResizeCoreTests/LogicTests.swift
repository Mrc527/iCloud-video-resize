import XCTest
import Photos
@testable import VideoResizeCore

final class BitrateTests: XCTestCase {
    func testReferenceIs1080p30() {
        let rate = Bitrate.target(width: 1920, height: 1080, fps: 30, quality: .balanced)
        XCTAssertEqual(rate, 5_000_000, accuracy: 1)
    }

    func test4KNeedsLessThanFourTimes1080p() {
        let hd = Bitrate.target(width: 1920, height: 1080, fps: 30, quality: .balanced)
        let uhd = Bitrate.target(width: 3840, height: 2160, fps: 30, quality: .balanced)
        XCTAssertGreaterThan(uhd, hd * 2)
        XCTAssertLessThan(uhd, hd * 4)
    }

    func testPortraitAndLandscapeAreEqual() {
        XCTAssertEqual(Bitrate.target(width: 1080, height: 1920, fps: 30, quality: .high),
                       Bitrate.target(width: 1920, height: 1080, fps: 30, quality: .high))
    }

    func testHigherFrameRateNeedsMoreBits() {
        XCTAssertGreaterThan(Bitrate.target(width: 1920, height: 1080, fps: 60, quality: .balanced),
                             Bitrate.target(width: 1920, height: 1080, fps: 30, quality: .balanced))
    }

    func testExpectedSaving() {
        let saving = Bitrate.expectedSaving(sourceBitrate: 10_000_000, width: 1920, height: 1080,
                                            fps: 30, quality: .balanced)
        XCTAssertEqual(saving, 50, accuracy: 0.01)
    }
}

final class PolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let settings = AppSettings()

    /// A one minute 1080p video at 16 Mbit/s, one year old.
    private func item(id: String = "A", size: Int64 = 120_000_000, age: Double = 365,
                      skip: String? = nil) -> VideoItem {
        VideoItem(id: id, filename: "IMG_0001.MOV",
                  creationDate: now.addingTimeInterval(-age * 86_400), duration: 60,
                  width: 1920, height: 1080, fileSize: size, skipReason: skip)
    }

    private func decide(_ item: VideoItem, record: Record? = nil,
                        outputs: Set<String> = []) -> Decision {
        Policy.decide(item: item, record: record, settings: settings, outputs: outputs, now: now)
    }

    func testNormalVideoIsProcessed() {
        XCTAssertEqual(decide(item()), .process)
    }

    func testOwnOutputIsLeftAlone() {
        XCTAssertEqual(decide(item(), outputs: ["A"]), .leave("Re-encoded by this app"))
    }

    func testSpecialVideosAreLeftAlone() {
        XCTAssertEqual(decide(item(skip: "Slow motion video")), .leave("Slow motion video"))
    }

    func testSmallVideoIsLeftAlone() {
        XCTAssertEqual(decide(item(size: 5_000_000)), .leave("Smaller than 20 MB"))
    }

    func testRecentVideoIsLeftAlone() {
        XCTAssertEqual(decide(item(age: 1)), .leave("Newer than 7 days"))
    }

    func testWellCompressedVideoIsLeftAlone() {
        // 60 s at about 5.3 Mbit/s: the target is 5, so there is little to save.
        XCTAssertEqual(decide(item(size: 40_000_000)), .leave("Already well compressed"))
    }

    func testUnknownSizeIsLeftAlone() {
        XCTAssertEqual(decide(item(size: 0)), .leave("File size not available"))
    }

    func testFailedVideoIsRetriedUntilTheLimit() {
        let once = Record(status: .failed, filename: "x", detail: "boom", attempts: 1)
        XCTAssertEqual(decide(item(), record: once), .process)

        let tooMany = Record(status: .failed, filename: "x", detail: "boom",
                             attempts: Policy.maxAttempts)
        XCTAssertEqual(decide(item(), record: tooMany), .leave("Failed 3 times: boom"))
    }

    func testHandledVideosAreNeverProcessedAgain() {
        for status in [Status.importing, .replaced, .deleted, .notWorth, .skipped, .needsReview] {
            let record = Record(status: status, filename: "x", detail: "d")
            XCTAssertNotEqual(decide(item(), record: record), .process, "\(status)")
        }
    }
}

final class StateStoreTests: TempDirectoryTestCase {
    func testRecordsSurviveARestart() {
        let url = temp.appendingPathComponent("state.json")
        let store = StateStore(url: url)
        store.set(Record(status: .replaced, filename: "a.mov", originalSize: 100, newSize: 40,
                         newIdentifier: "NEW"), for: "A")

        let reopened = StateStore(url: url)
        XCTAssertEqual(reopened.record(for: "A")?.status, .replaced)
        XCTAssertEqual(reopened.record(for: "A")?.newIdentifier, "NEW")
        XCTAssertEqual(reopened.record(for: "A")?.newSize, 40)
    }

    func testInterruptedImportIsFlagged() {
        let url = temp.appendingPathComponent("state.json")
        let store = StateStore(url: url)
        store.set(Record(status: .importing, filename: "a.mov"), for: "A")
        store.set(Record(status: .replaced, filename: "b.mov"), for: "B")

        let reopened = StateStore(url: url)
        XCTAssertEqual(reopened.recoverInterrupted(), 1)
        XCTAssertEqual(reopened.record(for: "A")?.status, .needsReview)
        XCTAssertEqual(reopened.record(for: "B")?.status, .replaced)
    }

    func testUnreadableFileIsKeptNotOverwritten() throws {
        let url = temp.appendingPathComponent("state.json")
        try Data("not json".utf8).write(to: url)

        let store = StateStore(url: url)
        XCTAssertTrue(store.records.isEmpty)
        let backup = url.appendingPathExtension("unreadable")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "not json")
    }
}

final class FFmpegArgumentsTests: XCTestCase {
    private func info(tenBit: Bool) -> MediaInfo {
        MediaInfo(duration: 10, width: 1920, height: 1080, fps: 30, videoBitrate: 10_000_000,
                  isHEVC: false, is10Bit: tenBit, videoTrackCount: 1, audioTrackCount: 1,
                  fileSize: 1, hasCaptureDate: true, hasLocation: false,
                  colorPrimaries: tenBit ? "ITU_R_2020" : "ITU_R_709_2",
                  transferFunction: tenBit ? "ITU_R_2100_HLG" : "ITU_R_709_2",
                  colorMatrix: tenBit ? "ITU_R_2020" : "ITU_R_709_2")
    }

    private func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).map { args[$0 + 1] }
    }

    func testUncompressedAudioBecomesAACAndTheTypeStays() {
        var info = info(tenBit: false)
        info.aacBitrates = [0, 256_000]
        let args = FFmpegTranscoder.arguments(
            source: URL(fileURLWithPath: "/C0001.MP4"), destination: URL(fileURLWithPath: "/C0001.MP4"),
            info: info, quality: .balanced)
        XCTAssertEqual(value(after: "-c:a", in: args), "copy")
        XCTAssertNil(value(after: "-c:a:0", in: args))
        XCTAssertEqual(value(after: "-c:a:1", in: args), "aac")
        XCTAssertEqual(value(after: "-b:a:1", in: args), "256000")
        XCTAssertEqual(value(after: "-f", in: args), "mp4")
        XCTAssertEqual(Reencode.outputName(for: URL(fileURLWithPath: "/C0001.MP4")), "C0001.MP4")
        XCTAssertEqual(Reencode.outputName(for: URL(fileURLWithPath: "/IMG_1.MOV")), "IMG_1.MOV")
        XCTAssertEqual(Reencode.outputName(for: URL(fileURLWithPath: "/clip.avi")), "clip.mov")
    }

    func testHDRVideoKeeps10BitAndColour() {
        let args = FFmpegTranscoder.arguments(
            source: URL(fileURLWithPath: "/in.mov"), destination: URL(fileURLWithPath: "/out.mov"),
            info: info(tenBit: true), quality: .balanced)
        XCTAssertEqual(value(after: "-pix_fmt", in: args), "yuv420p10le")
        XCTAssertEqual(value(after: "-color_primaries", in: args), "bt2020")
        XCTAssertEqual(value(after: "-color_trc", in: args), "arib-std-b67")
        XCTAssertEqual(value(after: "-colorspace", in: args), "bt2020nc")
        XCTAssertEqual(value(after: "-crf", in: args), "24")
        XCTAssertEqual(args.last, "/out.mov")
    }

    func testSDRVideoStays8BitAndKeepsMetadataAndAudio() {
        let args = FFmpegTranscoder.arguments(
            source: URL(fileURLWithPath: "/in.mov"), destination: URL(fileURLWithPath: "/out.mov"),
            info: info(tenBit: false), quality: .compact)
        XCTAssertEqual(value(after: "-pix_fmt", in: args), "yuv420p")
        XCTAssertEqual(value(after: "-c:a", in: args), "copy")
        XCTAssertEqual(value(after: "-map_metadata", in: args), "-1", "Carryover puts it back")
        XCTAssertEqual(value(after: "-f", in: args), "mov")
        XCTAssertEqual(value(after: "-tag:v", in: args), "hvc1")
        XCTAssertEqual(value(after: "-crf", in: args), "27")
    }
}

final class EditKindTests: XCTestCase {
    func testWhichEditsAreKept() throws {
        func kind(_ types: [PHAssetResourceType]) -> PhotoKitLibrary.EditKind {
            PhotoKitLibrary.edit(in: Set(types))
        }
        XCTAssertEqual(kind([.video]), .none)
        XCTAssertEqual(kind([.video, .audio]), .none)
        XCTAssertEqual(kind([.video, .adjustmentData, .fullSizeVideo]), .keepable)
        XCTAssertEqual(kind([.video, .fullSizePhoto, .adjustmentData, .fullSizeVideo]), .keepable)
        // Edited in several steps, or with an edit file Photos does not document (seen as 16):
        // the edited version is still there.
        XCTAssertEqual(kind([.video, .adjustmentData, .fullSizeVideo, .adjustmentBaseVideo]), .keepable)
        let undocumented = try XCTUnwrap(PHAssetResourceType(rawValue: 16))
        XCTAssertEqual(kind([.video, .fullSizePhoto, .adjustmentData, .fullSizeVideo, undocumented]),
                       .keepable)
        // No edited version: not rendered by Photos yet, or a slow motion video.
        XCTAssertEqual(kind([.video, .adjustmentData]), .other)
        XCTAssertEqual(kind([.video, .fullSizePhoto, .adjustmentData]), .other)
        XCTAssertEqual(kind([.video, .fullSizeVideo]), .other)
        XCTAssertEqual(kind([.video, .adjustmentBaseVideo]), .other)
    }
}
