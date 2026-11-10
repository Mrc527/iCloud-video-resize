import Foundation

/// A video file found on a card or in a folder.
public struct SourceVideo: Identifiable, Equatable, Sendable {
    public let url: URL
    public let filename: String
    public let fileSize: Int64
    public let modified: Date?

    public init(url: URL, filename: String, fileSize: Int64, modified: Date?) {
        self.url = url
        self.filename = filename
        self.fileSize = fileSize
        self.modified = modified
    }

    /// Recognises the same file when the card is inserted again.
    public var id: String {
        "\(filename)|\(fileSize)|\(Int(modified?.timeIntervalSince1970 ?? 0))"
    }
}

public enum SourceScanner {
    /// Containers that iPadOS and macOS can read.
    public static let supported: Set<String> = ["mp4", "mov", "m4v"]
    /// Video formats we recognise but cannot read. They are reported to the user.
    public static let unsupported: Set<String> = ["mts", "m2ts", "mxf", "avi", "braw", "r3d", "crm"]

    public struct Result: Sendable {
        public var videos: [SourceVideo] = []
        public var unsupported: [String] = []
    }

    /// Find the videos in a folder and in all the folders inside it.
    public static func scan(folder: URL) -> Result {
        var result = Result()
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let files = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return result }

        for case let url as URL in files {
            let type = url.pathExtension.lowercased()
            if unsupported.contains(type) {
                result.unsupported.append(url.lastPathComponent)
                continue
            }
            guard supported.contains(type),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            result.videos.append(SourceVideo(
                url: url, filename: url.lastPathComponent,
                fileSize: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate))
        }
        result.videos.sort {
            ($0.modified ?? .distantPast, $0.filename) < ($1.modified ?? .distantPast, $1.filename)
        }
        result.unsupported.sort()
        return result
    }
}

public enum ImportOutcome: String, Codable, Sendable {
    case reencoded  // the smaller version is in Photos
    case original   // the file was added as it is
    case failed     // nothing was added
}

public struct ImportEntry: Codable, Equatable, Sendable {
    public var outcome: ImportOutcome
    public var filename: String
    public var originalSize: Int64
    public var newSize: Int64
    public var detail: String
    public var date: Date

    public init(outcome: ImportOutcome, filename: String, originalSize: Int64,
                newSize: Int64, detail: String, date: Date = Date()) {
        self.outcome = outcome
        self.filename = filename
        self.originalSize = originalSize
        self.newSize = newSize
        self.detail = detail
        self.date = date
    }
}

/// Remembers which files were imported, in a JSON file.
public final class ImportLog: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var stored: [String: ImportEntry] = [:]

    public init(url: URL) {
        self.url = url
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        stored = (try? decoder.decode([String: ImportEntry].self, from: data)) ?? [:]
    }

    public var entries: [String: ImportEntry] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    public func set(_ entry: ImportEntry, for id: String) {
        lock.lock(); defer { lock.unlock() }
        stored[id] = entry
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(stored) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Brings one video from a card into Photos, re-encoded when that saves space.
/// The file on the card is only read, never changed.
public final class Importer: @unchecked Sendable {
    private let sink: PhotoSink
    private let log: ImportLog
    private let workDirectory: URL

    public init(sink: PhotoSink, log: ImportLog, workDirectory: URL) {
        self.sink = sink
        self.log = log
        self.workDirectory = workDirectory
    }

    /// Never throws: the result is saved in the log.
    /// Returns nil when the work was cancelled before Photos was changed.
    @discardableResult
    public func importVideo(_ video: SourceVideo, settings: AppSettings,
                            progress: @escaping @Sendable (Phase, Double) -> Void) async -> ImportEntry? {
        let work = workDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: work) }
        let entry: ImportEntry
        do {
            entry = try await run(video, settings: settings, work: work, progress: progress)
        } catch is CancellationError {
            return nil
        } catch {
            entry = ImportEntry(outcome: .failed, filename: video.filename,
                                originalSize: video.fileSize, newSize: 0,
                                detail: error.localizedDescription)
        }
        log.set(entry, for: video.id)
        return entry
    }

    private func run(_ video: SourceVideo, settings: AppSettings, work: URL,
                     progress: @escaping @Sendable (Phase, Double) -> Void) async throws -> ImportEntry {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let free = try work.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        if let free, free < video.fileSize * 2 {
            throw MediaError.unsupported("not enough free space on this device for this video")
        }

        let info = try await Probe.info(video.url)
        let captureDate = info.captureDate ?? video.modified

        // Why the file is added as it is. nil means: re-encode it.
        var keepReason: String?
        if info.videoTrackCount != 1 {
            keepReason = "More than one video track"
        } else if Bitrate.expectedSaving(sourceBitrate: info.videoBitrate, width: info.width,
                                         height: info.height, fps: info.fps,
                                         quality: settings.quality) < settings.minSavingPercent {
            keepReason = "Already compact"
        }

        if keepReason == nil {
            let name = video.url.deletingPathExtension().lastPathComponent + ".mov"
            let destination = work.appendingPathComponent(name)
            do {
                progress(.encoding, 0)
                try await NativeTranscoder().transcode(
                    source: video.url, destination: destination, info: info,
                    quality: settings.quality) { progress(.encoding, $0) }
                try Task.checkCancellation()

                progress(.verifying, 0)
                let output = try await Verifier.verify(source: info, output: destination,
                                                       fullDecode: settings.fullVerify)
                let saving = 100 * (1 - Double(output.fileSize) / Double(max(info.fileSize, 1)))
                if saving >= settings.minSavingPercent {
                    try Task.checkCancellation()
                    progress(.importing, 0)
                    _ = try await sink.add(file: destination, creationDate: captureDate,
                                           latitude: info.latitude, longitude: info.longitude)
                    return ImportEntry(outcome: .reencoded, filename: video.filename,
                                       originalSize: info.fileSize, newSize: output.fileSize,
                                       detail: String(format: "Saved %.0f%%", saving))
                }
                keepReason = String(format: "Saving too small (%.0f%%)", saving)
            } catch MediaError.unsupported(let what) {
                // The encoder cannot handle this kind of video. Any other
                // error (for example an interrupted encode) is a failure,
                // so a big original is never added by mistake.
                keepReason = "Cannot re-encode: \(what)"
            }
        }

        try Task.checkCancellation()
        progress(.copying, 0)
        let copy = work.appendingPathComponent(video.filename)
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: video.url, to: copy)
        try Task.checkCancellation()

        progress(.importing, 0)
        _ = try await sink.add(file: copy, creationDate: captureDate,
                               latitude: info.latitude, longitude: info.longitude)
        return ImportEntry(outcome: .original, filename: video.filename,
                           originalSize: info.fileSize, newSize: info.fileSize,
                           detail: "Added as it is. \(keepReason ?? "")")
    }
}
