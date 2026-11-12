import AVFoundation
import CoreMedia
import Foundation

public enum MediaError: LocalizedError {
    case noVideoTrack
    case unsupported(String)
    case encodingFailed(String)
    case verification(String)

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The file has no video track"
        case .unsupported(let what): return "Not supported: \(what)"
        case .encodingFailed(let why): return "Encoding failed: \(why)"
        case .verification(let why): return "The new file failed the check: \(why)"
        }
    }
}

public struct MediaInfo: Equatable, Sendable {
    public var duration: Double
    public var width: Int   // as shown on screen (rotation applied)
    public var height: Int
    public var fps: Double
    public var videoBitrate: Double
    public var isHEVC: Bool
    public var is10Bit: Bool
    public var videoTrackCount: Int
    public var audioTrackCount: Int
    public var fileSize: Int64
    public var hasCaptureDate: Bool
    public var hasLocation: Bool
    // CoreVideo names, for example "ITU_R_709_2".
    public var colorPrimaries: String?
    public var transferFunction: String?
    public var colorMatrix: String?
    // When and where the video was shot, when the file says it.
    public var captureDate: Date? = nil
    public var latitude: Double? = nil
    public var longitude: Double? = nil
    /// For each audio track: the AAC bit rate it is converted to, 0 when copied as it is.
    public var aacBitrates: [Int] = []
}

public enum Probe {
    public static func info(_ url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = videoTracks.first else { throw MediaError.noVideoTrack }

        let (size, transform, fps, rate, descriptions) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate,
            .formatDescriptions)
        let shown = CGRect(origin: .zero, size: size).applying(transform)
        let description = descriptions.first

        let metadata = (try? await asset.loadMetadata(for: .quickTimeMetadata)) ?? []
        let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        var bitrate = Double(rate)
        if bitrate <= 0, duration > 0 { bitrate = Double(fileSize) * 8 / duration }

        var captureDate: Date?
        if let item = try? await asset.load(.creationDate) {
            captureDate = try? await item.load(.dateValue)
        }
        var place: (latitude: Double, longitude: Double)?
        let common = (try? await asset.load(.commonMetadata)) ?? []
        if let item = AVMetadataItem.metadataItems(
            from: common, filteredByIdentifier: .commonIdentifierLocation).first,
           let text = try? await item.load(.stringValue) {
            place = ISO6709.parse(text)
        }

        let transfer = description.flatMap { string($0, kCMFormatDescriptionExtension_TransferFunction) }
        var aacBitrates: [Int] = []
        for audio in audioTracks {
            let format = try await audio.load(.formatDescriptions).first
            aacBitrates.append(NativeTranscoder.aacBitrate(for: format) ?? 0)
        }
        return MediaInfo(
            duration: duration,
            width: Int(abs(shown.width).rounded()),
            height: Int(abs(shown.height).rounded()),
            fps: Double(fps),
            videoBitrate: bitrate,
            isHEVC: description.map(isHEVC) ?? false,
            is10Bit: description.map { bitDepth($0, transfer: transfer) >= 10 } ?? false,
            videoTrackCount: videoTracks.count,
            audioTrackCount: audioTracks.count,
            fileSize: fileSize,
            hasCaptureDate: has(metadata, .quickTimeMetadataCreationDate),
            hasLocation: has(metadata, .quickTimeMetadataLocationISO6709),
            colorPrimaries: description.flatMap { string($0, kCMFormatDescriptionExtension_ColorPrimaries) },
            transferFunction: transfer,
            colorMatrix: description.flatMap { string($0, kCMFormatDescriptionExtension_YCbCrMatrix) },
            captureDate: captureDate,
            latitude: place?.latitude,
            longitude: place?.longitude,
            aacBitrates: aacBitrates
        )
    }

    private static func has(_ metadata: [AVMetadataItem], _ identifier: AVMetadataIdentifier) -> Bool {
        !AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).isEmpty
    }

    static func string(_ description: CMFormatDescription, _ key: CFString) -> String? {
        CMFormatDescriptionGetExtension(description, extensionKey: key) as? String
    }

    private static func isHEVC(_ description: CMFormatDescription) -> Bool {
        let hev1: FourCharCode = 0x6865_7631  // 'hev1'
        let codec = CMFormatDescriptionGetMediaSubType(description)
        return codec == kCMVideoCodecType_HEVC
            || codec == kCMVideoCodecType_DolbyVisionHEVC
            || codec == hev1
    }

    /// Bit depth of the video. Getting this wrong would turn HDR into SDR, so
    /// three sources are checked, from the most to the least direct.
    private static func bitDepth(_ description: CMFormatDescription, transfer: String?) -> Int {
        if let bits = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int {
            return bits
        }
        let atoms = CMFormatDescriptionGetExtension(
            description,
            extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
            as? [String: Any]
        // The HEVC configuration record stores "bit depth minus 8" in byte 17.
        if let hvcC = atoms?["hvcC"] as? Data, hvcC.count > 17 {
            return Int(hvcC[hvcC.startIndex + 17] & 0x07) + 8
        }
        // H.264 from cameras: the profiles High 10, High 4:2:2 and High 4:4:4
        // are the ones used for 10-bit video. Byte 1 of the record is the profile.
        if let avcC = atoms?["avcC"] as? Data, avcC.count > 1,
           [110, 122, 244].contains(avcC[avcC.startIndex + 1]) {
            return 10
        }
        // HDR video (HLG or PQ) is always 10 bit or more.
        if let transfer, transfer.contains("HLG") || transfer.contains("2084") {
            return 10
        }
        return 8
    }
}

/// Reads a position written as "+45.4642+009.1900+120.000/".
public enum ISO6709 {
    public static func parse(_ text: String) -> (latitude: Double, longitude: Double)? {
        let characters = Array(text.trimmingCharacters(in: .whitespaces))
        // The latitude ends where the second sign begins.
        guard characters.count > 2,
              let split = characters.indices.dropFirst().first(where: {
                  characters[$0] == "+" || characters[$0] == "-"
              })
        else { return nil }
        let rest = characters[split...]
        let end = rest.indices.dropFirst().first(where: {
            rest[$0] == "+" || rest[$0] == "-" || rest[$0] == "/"
        }) ?? rest.endIndex
        guard let latitude = Double(String(characters[..<split])),
              let longitude = Double(String(characters[split..<end])),
              abs(latitude) <= 90, abs(longitude) <= 180
        else { return nil }
        return (latitude, longitude)
    }
}

public enum Verifier {
    /// Throws unless the new file is a faithful copy of the original. With `original`, it
    /// also checks that every box, tag and extra track of the original is in the new file.
    /// `progress` follows the full decode, the long part.
    @discardableResult
    public static func verify(source: MediaInfo, output url: URL, original: URL? = nil,
                              fullDecode: Bool,
                              progress: @escaping @Sendable (Double) -> Void = { _ in })
        async throws -> MediaInfo {
        if let original {
            let missing = try Carryover.differences(original: original, output: url)
            if !missing.isEmpty {
                throw MediaError.verification("it would lose " + missing.joined(separator: ", "))
            }
        }
        let output = try await Probe.info(url)

        guard output.isHEVC else { throw MediaError.verification("the video is not HEVC") }
        guard output.videoTrackCount == 1 else {
            throw MediaError.verification("wrong number of video tracks")
        }
        guard (output.width, output.height) == (source.width, source.height) else {
            throw MediaError.verification(
                "resolution changed from \(source.width)x\(source.height) "
                + "to \(output.width)x\(output.height)")
        }
        let tolerance = max(0.5, source.duration * 0.01)
        guard abs(output.duration - source.duration) <= tolerance else {
            throw MediaError.verification(String(
                format: "duration changed from %.2f s to %.2f s", source.duration, output.duration))
        }
        guard output.audioTrackCount == source.audioTrackCount else {
            throw MediaError.verification(
                "audio tracks changed from \(source.audioTrackCount) to \(output.audioTrackCount)")
        }
        if source.is10Bit && !output.is10Bit {
            throw MediaError.verification("10-bit video became 8-bit")
        }
        if source.hasCaptureDate && !output.hasCaptureDate {
            throw MediaError.verification("the capture date was lost")
        }
        if source.hasLocation && !output.hasLocation {
            throw MediaError.verification("the GPS position was lost")
        }
        if fullDecode {
            try await decodeAll(url, progress: progress)
        }
        return output
    }

    /// Decode every frame, to be sure the file is not damaged.
    private static func decodeAll(_ url: URL,
                                  progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.noVideoTrack
        }
        let (rate, timeRange) = try await track.load(.nominalFrameRate, .timeRange)
        let estimate = Double(rate) * timeRange.duration.seconds
        let expected = estimate.isFinite ? max(estimate, 1) : 1
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaError.verification("cannot read the file") }
        reader.add(output)
        guard reader.startReading() else {
            throw MediaError.verification(reader.error?.localizedDescription ?? "cannot read the file")
        }

        let frames = await Task.detached(priority: .utility) { () -> Int in
            var count = 0
            while output.copyNextSampleBuffer() != nil {
                count += 1
                if count % 30 == 0 { progress(min(Double(count) / expected, 1)) }
            }
            return count
        }.value

        guard reader.status == .completed, frames > 0 else {
            throw MediaError.verification(
                "the file does not decode: \(reader.error?.localizedDescription ?? "no frames")")
        }
    }
}
