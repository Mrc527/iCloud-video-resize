import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

public protocol Transcoder: Sendable {
    /// Re-encode `source` to HEVC at the same resolution. Audio is copied as is.
    func transcode(source: URL, destination: URL, info: MediaInfo, quality: Quality,
                   progress: @escaping @Sendable (Double) -> Void) async throws
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
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        // Capture date, GPS, camera model.
        writer.metadata = try await asset.loadMetadata(for: .quickTimeMetadata)
        writer.shouldOptimizeForNetworkUse = true

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

        // Audio: copied without re-encoding.
        for track in audioTracks {
            let hint = try await track.load(.formatDescriptions).first
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                           sourceFormatHint: hint)
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
        args += [
            "-tag:v", "hvc1",       // needed by Apple players
            "-c:a", "copy",
            "-map_metadata", "0",   // capture date, GPS, camera model
            "-movflags", "+faststart+use_metadata_tags",
            "-f", "mov", destination.path,
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
