import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

public protocol Transcoder: Sendable {
    /// Re-encode `source` to HEVC at the same resolution. Audio is copied as is, except
    /// uncompressed stereo or mono audio, which becomes AAC. The movie index must end the file.
    func transcode(source: URL, destination: URL, info: MediaInfo, quality: Quality,
                   progress: @escaping @Sendable (Double) -> Void) async throws
}

/// Encoding as both apps do it: encode, then put back everything else of the original.
public enum Reencode {
    /// The name of the new file: the same as the original, so the video looks the same in
    /// Photos. Types the writer cannot make become .mov.
    public static func outputName(for source: URL) -> String {
        if fileType(for: source) != nil { return source.lastPathComponent }
        return source.deletingPathExtension().lastPathComponent + ".mov"
    }

    static func fileType(for url: URL) -> AVFileType? {
        switch url.pathExtension.lowercased() {
        case "mov": return .mov
        case "mp4": return .mp4
        case "m4v": return .m4v
        default: return nil
        }
    }

    public static func run(_ transcoder: Transcoder, source: URL, destination: URL, info: MediaInfo,
                           quality: Quality,
                           progress: @escaping @Sendable (Double) -> Void) async throws {
        let encoded = destination.deletingLastPathComponent()
            .appendingPathComponent("encoded-" + destination.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: encoded) }
        try await transcoder.transcode(source: source, destination: encoded, info: info,
                                       quality: quality, progress: progress)
        try Task.checkCancellation()
        try Carryover.apply(original: source, encoded: encoded, output: destination)
    }
}

// MARK: - Apple encoder

/// Uses AVFoundation and the hardware HEVC encoder. No extra software needed.
public struct NativeTranscoder: Transcoder {
    public init() {}

    public func transcode(source: URL, destination: URL, info: MediaInfo, quality: Quality,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.noVideoTrack
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let (naturalSize, transform, descriptions) = try await videoTrack.load(
            .naturalSize, .preferredTransform, .formatDescriptions)
        let duration = try await asset.load(.duration).seconds

        let reader = try AVAssetReader(asset: asset)
        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination,
                                       fileType: Reencode.fileType(for: destination) ?? .mov)
        // Capture date, GPS, camera model. Carryover then writes them byte for byte.
        writer.metadata = try await asset.loadMetadata(for: .quickTimeMetadata)
        writer.shouldOptimizeForNetworkUse = false  // the index at the end, for Carryover

        // Video: decode to raw frames, encode again as HEVC.
        let pixelFormat = info.is10Bit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw MediaError.unsupported("video track") }
        reader.add(videoOutput)

        let bitrate = Bitrate.target(width: info.width, height: info.height,
                                     fps: info.fps, quality: quality)
        let profile = info.is10Bit
            ? kVTProfileLevel_HEVC_Main10_AutoLevel
            : kVTProfileLevel_HEVC_Main_AutoLevel
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(bitrate),
            AVVideoProfileLevelKey: profile as String,
        ]
        if info.fps > 0 {
            compression[AVVideoExpectedSourceFrameRateKey] = Int(info.fps.rounded())
        }
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(naturalSize.width),
            AVVideoHeightKey: Int(naturalSize.height),
            AVVideoCompressionPropertiesKey: compression,
        ]
        // Keep the colour tags so HDR stays HDR. Unusual values are left to the encoder.
        if let color = Self.colorProperties(descriptions.first) {
            var tagged = settings
            tagged[AVVideoColorPropertiesKey] = color
            if writer.canApply(outputSettings: tagged, forMediaType: .video) {
                settings = tagged
            }
        }
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw MediaError.unsupported("HEVC encoding of this video on this Mac")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.transform = transform  // keeps portrait videos portrait
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw MediaError.unsupported("video track") }
        writer.add(videoInput)

        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput, Bool)] = [(videoOutput, videoInput, true)]

        // Audio: copied without re-encoding. Uncompressed audio from cameras becomes AAC:
        // it would be about a tenth of the new file.
        for track in audioTracks {
            let hint = try await track.load(.formatDescriptions).first
            let aac = Self.aacSettings(for: hint)
            let output = AVAssetReaderTrackOutput(
                track: track, outputSettings: aac == nil ? nil : [AVFormatIDKey: kAudioFormatLinearPCM])
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aac,
                                           sourceFormatHint: aac == nil ? hint : nil)
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(output), writer.canAdd(input) else {
                throw MediaError.unsupported("audio track")
            }
            reader.add(output)
            writer.add(input)
            pairs.append((output, input, false))
        }

        guard writer.startWriting() else {
            throw MediaError.encodingFailed(writer.error?.localizedDescription ?? "cannot start")
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw MediaError.encodingFailed(reader.error?.localizedDescription ?? "cannot read")
        }
        writer.startSession(atSourceTime: .zero)

        let lastReported = Box(0.0)
        let onVideoSample: @Sendable (CMTime) -> Void = { time in
            guard duration > 0 else { return }
            let fraction = min(max(time.seconds / duration, 0), 1)
            if fraction - lastReported.value >= 0.01 {
                lastReported.value = fraction
                progress(fraction)
            }
        }

        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                for (index, pair) in pairs.enumerated() {
                    let (output, input, isVideo) = pair
                    let queue = DispatchQueue(label: "transcode.track.\(index)")
                    group.addTask {
                        await Self.pump(from: output, to: input, on: queue,
                                        onSample: isVideo ? onVideoSample : nil)
                    }
                }
            }
        } onCancel: {
            reader.cancelReading()  // makes every pump stop
        }

        if Task.isCancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        }
        if reader.status != .completed || writer.status == .failed {
            let reason = reader.error?.localizedDescription
                ?? writer.error?.localizedDescription ?? "unknown error"
            writer.cancelWriting()
            throw MediaError.encodingFailed(reason)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw MediaError.encodingFailed(writer.error?.localizedDescription ?? "cannot finish")
        }
        progress(1)
    }

    /// Move every sample of one track from the reader to the writer.
    private static func pump(from output: AVAssetReaderOutput, to input: AVAssetWriterInput,
                             on queue: DispatchQueue,
                             onSample: (@Sendable (CMTime) -> Void)?) async {
        let finished = Box(false)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                guard !finished.value else { return }
                while input.isReadyForMoreMediaData {
                    guard let buffer = output.copyNextSampleBuffer() else {
                        finished.value = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    onSample?(CMSampleBufferGetPresentationTimeStamp(buffer))
                    if !input.append(buffer) {
                        // The writer failed. Its status tells the caller.
                        finished.value = true
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }

    /// AAC settings for uncompressed mono or stereo audio, nil for anything else.
    static func aacSettings(for description: CMFormatDescription?) -> [String: Any]? {
        guard let bitrate = aacBitrate(for: description), let description,
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { return nil }
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.mSampleRate,
            AVNumberOfChannelsKey: Int(format.mChannelsPerFrame),
            AVEncoderBitRateKey: bitrate,
        ]
    }

    /// The AAC bit rate for uncompressed mono or stereo audio: 128 kbit/s per channel.
    /// nil for audio that is copied as it is.
    static func aacBitrate(for description: CMFormatDescription?) -> Int? {
        guard let description,
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mFormatID == kAudioFormatLinearPCM,
              (1...2).contains(format.mChannelsPerFrame),
              [44_100, 48_000].contains(format.mSampleRate)
        else { return nil }
        return 128_000 * Int(format.mChannelsPerFrame)
    }

    private static func colorProperties(_ description: CMFormatDescription?) -> [String: Any]? {
        guard let description,
              let primaries = Probe.string(description, kCMFormatDescriptionExtension_ColorPrimaries),
              let transfer = Probe.string(description, kCMFormatDescriptionExtension_TransferFunction),
              let matrix = Probe.string(description, kCMFormatDescriptionExtension_YCbCrMatrix)
        else { return nil }
        return [
            AVVideoColorPrimariesKey: primaries,
            AVVideoTransferFunctionKey: transfer,
            AVVideoYCbCrMatrixKey: matrix,
        ]
    }
}

// MARK: - ffmpeg

#if os(macOS)

/// Uses an installed ffmpeg with libx265. Slow, but the files are smaller.
public struct FFmpegTranscoder: Transcoder {
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    /// Find ffmpeg: the path from the settings first, then the Homebrew places.
    public static func locate(custom: String = "") -> URL? {
        let candidates = [custom, "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        return candidates
            .filter { !$0.isEmpty }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    public static func arguments(source: URL, destination: URL, info: MediaInfo,
                                 quality: Quality) -> [String] {
        var args = [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-progress", "pipe:1", "-nostats",
            "-i", source.path,
            "-map", "0:v:0", "-map", "0:a?",
            "-c:v", "libx265", "-crf", String(quality.crf), "-preset", "medium",
            "-x265-params", "log-level=error",
            "-pix_fmt", info.is10Bit ? "yuv420p10le" : "yuv420p",
        ]
        let color: [(String, String?, [String: String])] = [
            ("-color_primaries", info.colorPrimaries,
             ["ITU_R_709_2": "bt709", "ITU_R_2020": "bt2020", "P3_D65": "smpte432",
              "SMPTE_C": "smpte170m", "EBU_3213": "bt470bg"]),
            ("-color_trc", info.transferFunction,
             ["ITU_R_709_2": "bt709", "ITU_R_2100_HLG": "arib-std-b67",
              "SMPTE_ST_2084_PQ": "smpte2084", "IEC_sRGB": "iec61966-2-1"]),
            ("-colorspace", info.colorMatrix,
             ["ITU_R_709_2": "bt709", "ITU_R_2020": "bt2020nc", "ITU_R_601_4": "smpte170m"]),
        ]
        for (flag, value, names) in color {
            if let value, let name = names[value] { args += [flag, name] }
        }
        args += ["-tag:v", "hvc1", "-c:a", "copy"]  // hvc1: needed by Apple players
        // The last matching option wins: uncompressed tracks become AAC.
        for (index, bitrate) in info.aacBitrates.enumerated() where bitrate > 0 {
            args += ["-c:a:\(index)", "aac", "-b:a:\(index)", "\(bitrate)"]
        }
        let mp4 = Reencode.fileType(for: destination) == .mp4 || Reencode.fileType(for: destination) == .m4v
        args += [
            // ffmpeg writes metadata its own way: Carryover puts back the original's exactly.
            "-map_metadata", "-1",
            "-f", mp4 ? "mp4" : "mov", destination.path,  // the index at the end, for Carryover
        ]
        return args
    }

    public func transcode(source: URL, destination: URL, info: MediaInfo, quality: Quality,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments(source: source, destination: destination,
                                           info: info, quality: quality)
        process.qualityOfService = .utility
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let duration = info.duration
        stdout.fileHandleForReading.readabilityHandler = { handle in
            guard let text = String(data: handle.availableData, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                if let micros = Double(line.dropFirst("out_time_us=".count)), duration > 0 {
                    progress(min(max(micros / 1_000_000 / duration, 0), 1))
                }
            }
        }
        let errors = Box(Data())
        stderr.fileHandleForReading.readabilityHandler = { handle in
            errors.value += handle.availableData
        }
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        if Task.isCancelled {
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        }
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.value.suffix(600), encoding: .utf8) ?? ""
            throw MediaError.encodingFailed(
                "ffmpeg: " + message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        progress(1)
    }
}
#endif
