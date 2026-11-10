import AVFoundation
import Foundation
import XCTest
@testable import VideoResizeCore

enum Sample {
    static let captureDate = "2020-01-01T10:00:00+0100"

    /// A short H.264 clip of moving noise, encoded wastefully like a camera would.
    static func makeVideo(at url: URL, seconds: Int = 2, width: Int = 640,
                          height: Int = 360) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let date = AVMutableMetadataItem()
        date.identifier = .quickTimeMetadataCreationDate
        date.value = captureDate as NSString
        date.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [date]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<(seconds * 30) {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            var created: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
            guard let buffer = created else { throw CocoaError(.fileWriteUnknown) }

            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                arc4random_buf(base, CVPixelBufferGetBytesPerRow(buffer) * height)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])

            let time = CMTime(value: CMTimeValue(frame), timescale: 30)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    /// Copy `video` and add an audio track taken from a system sound.
    static func addAudio(to video: URL, output: URL) async throws {
        let sound = URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")
        guard FileManager.default.fileExists(atPath: sound.path) else {
            throw XCTSkip("System sound not available on this machine")
        }
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: sound)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first
        else { throw CocoaError(.fileReadUnknown) }
        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)

        let composition = AVMutableComposition()
        guard let outVideo = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let outAudio = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw CocoaError(.fileWriteUnknown) }
        try outVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration),
                                     of: videoTrack, at: .zero)
        try outAudio.insertTimeRange(
            CMTimeRange(start: .zero, duration: CMTimeMinimum(videoDuration, audioDuration)),
            of: audioTrack, at: .zero)

        try? FileManager.default.removeItem(at: output)
        guard let export = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetPassthrough)
        else { throw CocoaError(.fileWriteUnknown) }
        export.outputURL = output
        export.outputFileType = .mov
        await export.export()
        guard export.status == .completed else {
            throw export.error ?? CocoaError(.fileWriteUnknown)
        }
    }
}

/// A photo library that lives in memory.
final class FakeLibrary: VideoLibrary, @unchecked Sendable {
    var files: [String: URL] = [:]
    var present: Set<String> = []
    var imported: [String: String] = [:]  // new identifier -> file name
    var parked: [String] = []
    var failImport = false

    func add(_ id: String, file: URL) {
        files[id] = file
        present.insert(id)
    }

    func listVideos() async throws -> [VideoItem] { [] }

    func downloadOriginal(_ item: VideoItem, to directory: URL,
                          progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let file = files[item.id] else { throw LibraryError.notFound }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent(item.filename)
        try FileManager.default.copyItem(at: file, to: copy)
        return copy
    }

    func importReplacement(file: URL, for item: VideoItem) async throws -> String {
        if failImport { throw LibraryError.importFailed }
        let id = "NEW-" + item.id
        imported[id] = file.lastPathComponent
        present.insert(id)
        return id
    }

    func exists(_ id: String) -> Bool { present.contains(id) }

    func park(original id: String, albumTitle: String) async throws { parked.append(id) }

    func delete(_ ids: [String]) async throws { present.subtract(ids) }
}

class TempDirectoryTestCase: XCTestCase {
    var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("icvr-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }
}
