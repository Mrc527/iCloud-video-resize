import AVFoundation
import Foundation
import XCTest
@testable import VideoResizeCore

enum Sample {
    static let captureDate = "2020-01-01T10:00:00+0100"

    /// A video as some drones and cameras write it: the position as a ©xyz user data tag,
    /// camera make and model, a timed GPS track, and a camera box at the end of the file.
    static func makeDroneVideo(at url: URL, movieTimeScale: CMTimeScale? = nil,
                               positionTrackFirst: Bool = false) async throws {
        try await makeVideo(at: url, userData: [
            .quickTimeUserDataLocationISO6709: "+46.0037+008.9511+273.000/",
            .quickTimeUserDataMake: "DJI",
            .quickTimeUserDataModel: "Mini 4 Pro",
        ], positionTrack: true, positionTrackFirst: positionTrackFirst,
           movieTimeScale: movieTimeScale)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        // Shot long ago: 2020-01-01, in seconds since 1904, in the movie header.
        let file = try MovieFile(url: url)
        let moov = try XCTUnwrap(file.topLevel.first { $0.type == "moov" })
        let mvhd = try XCTUnwrap(file.moov?.bytes.range(of: Data("mvhd".utf8)))
        var date = Data()
        date.append(uint32: 3_660_681_600)
        date.append(uint32: 3_660_681_600)
        try handle.seek(toOffset: moov.offset + UInt64(mvhd.upperBound) + 4)  // after version, flags
        try handle.write(contentsOf: date)
        try handle.seekToEnd()
        try handle.write(contentsOf: Boxes.make("uuid", Data(repeating: 0xAB, count: 16)
            + Data("<camera>settings</camera>".utf8)))
    }

    /// The positions of the timed GPS track, in order.
    static func timedPositions(in url: URL) async throws -> [String] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .metadata).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
        reader.startReading()
        var positions: [String] = []
        while let group = adaptor.nextTimedMetadataGroup() {
            for item in group.items { positions.append(try await item.load(.stringValue) ?? "?") }
        }
        return positions
    }

    /// Rewrite the movie index of a file made by AVAssetWriter. Its media data comes
    /// before the index, so no data moves.
    static func editMoov(_ url: URL, _ change: ([RawBox]) -> [Data]) throws {
        let file = try MovieFile(url: url)
        let top = try XCTUnwrap(file.topLevel.first { $0.type == "moov" })
        let moov = try XCTUnwrap(file.moov)
        let data = try Data(contentsOf: url)
        let edited = data.prefix(Int(top.offset)) + Boxes.container("moov", change(moov.children))
            + data.suffix(from: Int(top.offset + top.size))
        try edited.write(to: url)
    }

    /// A short H.264 clip of moving noise, encoded wastefully like a camera would.
    static func makeVideo(at url: URL, seconds: Int = 2, width: Int = 640,
                          height: Int = 360, location: String? = nil,
                          userData: [AVMetadataIdentifier: String] = [:],
                          positionTrack: Bool = false, positionTrackFirst: Bool = false,
                          movieTimeScale: CMTimeScale? = nil, language: String? = nil) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        if let movieTimeScale { writer.movieTimeScale = movieTimeScale }

        func text(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            return item
        }
        writer.metadata = [text(.quickTimeMetadataCreationDate, captureDate)]
            + (location.map { [text(.quickTimeMetadataLocationISO6709, $0)] } ?? [])
            + userData.map { text($0.key, $0.value) }

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
        input.languageCode = language
        if !(positionTrack && positionTrackFirst) { writer.add(input) }
        var positions: AVAssetWriterInputMetadataAdaptor?
        if positionTrack {
            let specification: NSDictionary = [
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier:
                    AVMetadataIdentifier.quickTimeMetadataLocationISO6709.rawValue,
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType:
                    kCMMetadataDataType_QuickTimeMetadataLocation_ISO6709,
            ]
            var description: CMFormatDescription?
            CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
                allocator: nil, metadataType: kCMMetadataFormatType_Boxed,
                metadataSpecifications: [specification] as CFArray, formatDescriptionOut: &description)
            let track = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil,
                                           sourceFormatHint: description)
            track.expectsMediaDataInRealTime = false
            writer.add(track)
            if positionTrackFirst { writer.add(input) }  // the GPS track gets the first number
            track.addTrackAssociation(withTrackOf: input,
                                      type: AVAssetTrack.AssociationType.metadataReferent.rawValue)
            positions = AVAssetWriterInputMetadataAdaptor(assetWriterInput: track)
        }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<(seconds * 30) {
            if let positions, frame % 30 == 0 {
                let item = AVMutableMetadataItem()
                item.identifier = .quickTimeMetadataLocationISO6709
                item.dataType = kCMMetadataDataType_QuickTimeMetadataLocation_ISO6709 as String
                item.value = "+46.00\(frame / 30)7+008.9511+273.000/" as NSString
                let range = CMTimeRange(start: CMTime(value: CMTimeValue(frame), timescale: 30),
                                        duration: CMTime(value: 30, timescale: 30))
                while !positions.assetWriterInput.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                guard positions.append(AVTimedMetadataGroup(items: [item], timeRange: range)) else {
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
            }
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
        positions?.assetWriterInput.markAsFinished()
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
    var shared: Set<String> = []
    var toMove: Set<String> = []  // in the album of the videos to move to the Shared Library
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
        if shared.contains(item.id) { toMove.insert(id) }  // a new video is never shared
        return id
    }

    func exists(_ id: String) -> Bool { present.contains(id) }

    func inSharedLibrary(_ id: String) -> Bool? { shared.contains(id) }

    @discardableResult
    func addToAlbum(_ ids: [String], albumTitle: String) async throws -> Int {
        let missing = ids.filter(present.contains)
        switch albumTitle {
        case Pipeline.albumTitle:
            let added = missing.filter { !parked.contains($0) }
            parked += added
            return added.count
        case Pipeline.moveAlbumTitle:
            let added = Set(missing).subtracting(toMove)
            toMove.formUnion(added)
            return added.count
        default:
            return 0
        }
    }

    func removeFromAlbum(_ ids: [String], albumTitle: String) async throws {
        switch albumTitle {
        case Pipeline.albumTitle: parked.removeAll { ids.contains($0) }
        case Pipeline.moveAlbumTitle: toMove.subtract(ids)
        default: break
        }
    }

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
