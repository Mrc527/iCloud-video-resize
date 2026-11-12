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
    /// The device that imported the file. nil in logs written before iCloud sync.
    public var device: String?

    public init(outcome: ImportOutcome, filename: String, originalSize: Int64,
                newSize: Int64, detail: String, date: Date = Date(), device: String? = nil) {
        self.outcome = outcome
        self.filename = filename
        self.originalSize = originalSize
        self.newSize = newSize
        self.detail = detail
        self.date = date
        self.device = device
    }
}

/// Remembers which files were imported, in a JSON file.
public final class ImportLog: @unchecked Sendable {
    private let url: URL
    private let device: String?
    private let lock = NSLock()
    private var stored: [String: ImportEntry] = [:]

    /// `device` is written in the entries set on this device.
    public init(url: URL, device: String? = nil) {
        self.url = url
        self.device = device
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
        var entry = entry
        if entry.device == nil { entry.device = device }
        merge([id: entry])
    }

    /// Set several entries, with one write of the file.
    public func merge(_ entries: [String: ImportEntry]) {
        guard !entries.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        stored.merge(entries) { $1 }
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
        // Android phones and some cameras and drones write the position only as ©xyz or loci.
        let place = info.latitude.flatMap { latitude in info.longitude.map { (latitude, $0) } }
            ?? Carryover.userDataLocation(video.url)

        // Why the file is added as it is. nil means: re-encode it.
        var keepReason: String?
        let uncarried: String? = {
            do { try Carryover.check(video.url) } catch MediaError.unsupported(let what) {
                return what
            } catch {}
            return nil
        }()
        if info.videoTrackCount != 1 {
            keepReason = "More than one video track"
        } else if let uncarried {
            keepReason = "A new file could not carry \(uncarried)"
        } else if Bitrate.expectedSaving(sourceBitrate: info.videoBitrate, width: info.width,
                                         height: info.height, fps: info.fps,
                                         quality: settings.quality) < settings.minSavingPercent {
            keepReason = "Already compact"
        }

        if keepReason == nil {
            let destination = work.appendingPathComponent(Reencode.outputName(for: video.url))
            do {
                progress(.encoding, 0)
                try await Reencode.run(NativeTranscoder(), source: video.url, destination: destination,
                                       info: info, quality: settings.quality) { progress(.encoding, $0) }
                try Task.checkCancellation()

                progress(.verifying, 0)
                let output = try await Verifier.verify(source: info, output: destination,
                                                       original: video.url,
                                                       fullDecode: settings.fullVerify) {
                    progress(.verifying, $0)
                }
                let saving = 100 * (1 - Double(output.fileSize) / Double(max(info.fileSize, 1)))
                if saving >= settings.minSavingPercent {
                    try Task.checkCancellation()
                    progress(.importing, 0)
                    _ = try await sink.add(file: destination, creationDate: captureDate,
                                           latitude: place?.0, longitude: place?.1)
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
                               latitude: place?.0, longitude: place?.1)
        return ImportEntry(outcome: .original, filename: video.filename,
                           originalSize: info.fileSize, newSize: info.fileSize,
                           detail: "Added as it is. \(keepReason ?? "")")
    }
}

/// Videos copied from the card to this device, waiting to be re-encoded.
/// Once a video is here the card is no longer needed. The list survives a
/// restart of the app.
public final class Inbox: @unchecked Sendable {
    private struct Item: Codable {
        var filename: String
        var fileSize: Int64
        var modified: Date?
        var folder: String
        /// When the copy was made. nil for copies made by an older version.
        var copied: Date?
    }

    private let directory: URL
    private let lock = NSLock()
    private var items: [String: Item] = [:]

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: manifest),
           let decoded = try? JSONDecoder().decode([String: Item].self, from: data) {
            // Forget entries whose file is gone.
            items = decoded.filter { FileManager.default.fileExists(atPath: file($0.value).path) }
        }
    }

    private var manifest: URL { directory.appendingPathComponent("manifest.json") }

    private func file(_ item: Item) -> URL {
        directory.appendingPathComponent(item.folder).appendingPathComponent(item.filename)
    }

    /// The local copies, oldest video first. Each has the same `id` as the
    /// file on the card it was copied from.
    public var pending: [SourceVideo] {
        lock.lock(); defer { lock.unlock() }
        return items.values
            .map { SourceVideo(url: file($0), filename: $0.filename, fileSize: $0.fileSize,
                               modified: $0.modified) }
            .sorted {
                ($0.modified ?? .distantPast, $0.filename) < ($1.modified ?? .distantPast, $1.filename)
            }
    }

    public var totalBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return items.values.reduce(0) { $0 + $1.fileSize }
    }

    public func contains(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return items[id] != nil
    }

    /// Another device put this card file in Photos after it was copied here: the copy is
    /// not needed. A file chosen again on purpose was copied after that import, so it is
    /// still imported.
    public func importedElsewhere(_ id: String, log: ImportLog, device: String) -> Bool {
        let copied: Date? = { lock.lock(); defer { lock.unlock() }; return items[id]?.copied }()
        guard let entry = log.entries[id], entry.outcome != .failed,
              let other = entry.device, other != device, let copied
        else { return false }
        return entry.date > copied
    }

    /// Copy a video from the card. The file on the card is not changed.
    /// `progress` gets the share copied about once a second.
    public func add(_ video: SourceVideo,
                    progress: @escaping @Sendable (Double) -> Void = { _ in }) throws {
        if contains(video.id) { return }
        let item = Item(filename: video.filename, fileSize: video.fileSize,
                        modified: video.modified, folder: UUID().uuidString, copied: Date())
        let folder = directory.appendingPathComponent(item.folder)
        let destination = file(item)
        // The copy gives no progress: the size of the file being written tells it.
        let watcher = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watcher.schedule(deadline: .now() + 1, repeating: 1)
        watcher.setEventHandler {
            // Not URL.resourceValues: it keeps returning the first size it read.
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size]
                as? Int64 ?? 0
            progress(min(Double(size) / Double(max(video.fileSize, 1)), 1))
        }
        watcher.resume()
        defer { watcher.cancel() }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: video.url, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: folder)  // no half copied files
            throw error
        }
        lock.lock(); defer { lock.unlock() }
        items[video.id] = item
        save()
    }

    /// Delete the local copy. The file on the card is not touched.
    public func remove(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        guard let item = items.removeValue(forKey: id) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(item.folder))
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: manifest, options: .atomic)
    }
}
