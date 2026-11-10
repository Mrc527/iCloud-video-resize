import Foundation

public enum Phase: String, Sendable {
    case downloading = "Downloading"
    case encoding = "Encoding"
    case verifying = "Checking"
    case importing = "Adding to Photos"
}

/// The work done on one video: download, encode, verify, replace.
public final class Pipeline: @unchecked Sendable {
    public static let albumTitle = "Video Resize: originals to delete"

    private let library: VideoLibrary
    private let store: StateStore
    private let workDirectory: URL

    public init(library: VideoLibrary, store: StateStore, workDirectory: URL) {
        self.library = library
        self.store = store
        self.workDirectory = workDirectory
    }

    /// Process one video. Never throws: the result is saved in the store.
    /// Returns nil when the work was cancelled before Photos was changed.
    @discardableResult
    public func process(_ item: VideoItem, settings: AppSettings,
                        progress: @escaping @Sendable (Phase, Double) -> Void) async -> Record? {
        let work = workDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: work) }
        let attempts = store.record(for: item.id)?.attempts ?? 0

        do {
            var record = try await run(item, settings: settings, work: work, progress: progress)
            record.attempts = attempts
            store.set(record, for: item.id)
            return record
        } catch {
            // An error after the import started must not be retried blindly:
            // the new video may already be in Photos.
            let current = store.record(for: item.id)
            let importing = current?.status == .importing
            if error is CancellationError && !importing { return nil }

            var record = current ?? Record(status: .failed, filename: item.filename)
            record.status = importing ? .needsReview : .failed
            record.detail = error.localizedDescription
            record.attempts = attempts + 1
            record.updatedAt = Date()
            store.set(record, for: item.id)
            return record
        }
    }

    private func run(_ item: VideoItem, settings: AppSettings, work: URL,
                     progress: @escaping @Sendable (Phase, Double) -> Void) async throws -> Record {
        let transcoder = try Self.transcoder(for: settings)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try checkFreeSpace(for: item, at: work)

        progress(.downloading, 0)
        let source = try await library.downloadOriginal(item, to: work.appendingPathComponent("in")) {
            progress(.downloading, $0)
        }
        try Task.checkCancellation()
        let info = try await Probe.info(source)

        if info.videoTrackCount != 1 {
            return Record(status: .skipped, filename: item.filename, originalSize: info.fileSize,
                          detail: "More than one video track (cinematic or spatial video)")
        }
        // Now the real frame rate and bit rate are known: check again.
        let expected = Bitrate.expectedSaving(sourceBitrate: info.videoBitrate, width: info.width,
                                              height: info.height, fps: info.fps,
                                              quality: settings.quality)
        if expected < settings.minSavingPercent {
            return Record(status: .notWorth, filename: item.filename, originalSize: info.fileSize,
                          detail: String(format: "Already well compressed (%.1f Mbit/s)",
                                         info.videoBitrate / 1_000_000))
        }

        // Same name as the original, so the video looks the same in Photos.
        let outputDirectory = work.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let name = source.pathExtension.lowercased() == "mov"
            ? source.lastPathComponent
            : source.deletingPathExtension().lastPathComponent + ".mov"
        let destination = outputDirectory.appendingPathComponent(name)

        progress(.encoding, 0)
        try await transcoder.transcode(source: source, destination: destination, info: info,
                                       quality: settings.quality) { progress(.encoding, $0) }
        try Task.checkCancellation()

        progress(.verifying, 0)
        let output = try await Verifier.verify(source: info, output: destination,
                                               fullDecode: settings.fullVerify)
        let saving = 100 * (1 - Double(output.fileSize) / Double(max(info.fileSize, 1)))
        if saving < settings.minSavingPercent {
            return Record(status: .notWorth, filename: item.filename, originalSize: info.fileSize,
                          newSize: output.fileSize,
                          detail: String(format: "Saving too small (%.0f%%)", saving))
        }
        try Task.checkCancellation()

        // From here Photos is changed. The intent is saved first, and the work
        // is no longer cancelled half way.
        progress(.importing, 0)
        var record = Record(status: .importing, filename: item.filename,
                            originalSize: info.fileSize, newSize: output.fileSize)
        store.set(record, for: item.id)
        let newIdentifier = try await library.importReplacement(file: destination, for: item)
        record.newIdentifier = newIdentifier
        store.set(record, for: item.id)

        guard library.exists(newIdentifier) else { throw LibraryError.importFailed }
        try await library.park(original: item.id, albumTitle: Self.albumTitle)

        record.status = .replaced
        record.detail = String(format: "Saved %.0f%%", saving)
        record.updatedAt = Date()
        return record
    }

    private static func transcoder(for settings: AppSettings) throws -> Transcoder {
        switch settings.encoder {
        case .native:
            return NativeTranscoder()
        case .ffmpeg:
            guard let executable = FFmpegTranscoder.locate(custom: settings.ffmpegPath) else {
                throw MediaError.unsupported("ffmpeg was not found. Install it or use the Apple encoder")
            }
            return FFmpegTranscoder(executable: executable)
        }
    }

    private func checkFreeSpace(for item: VideoItem, at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values.volumeAvailableCapacityForImportantUsage else { return }
        // Room for the original, the new file, and the copy Photos makes.
        if free < item.fileSize * 5 / 2 {
            throw MediaError.unsupported("not enough free disk space for this video")
        }
    }

    /// Delete the originals whose replacement is still in Photos.
    ///
    /// An original whose replacement is missing is held back and never deleted.
    public func deleteOriginals() async throws -> (deleted: Int, heldBack: Int) {
        var safe: [String] = []
        var heldBack = 0
        for (id, record) in store.records where record.status == .replaced {
            guard let newIdentifier = record.newIdentifier, library.exists(newIdentifier) else {
                heldBack += 1
                continue
            }
            if library.exists(id) {
                safe.append(id)
            } else {
                mark(id, record, detail: "The original was already deleted")
            }
        }
        if !safe.isEmpty {
            try await library.delete(safe)
            for id in safe {
                if let record = store.record(for: id) {
                    mark(id, record, detail: "The original is in Recently Deleted")
                }
            }
        }
        return (safe.count, heldBack)
    }

    private func mark(_ id: String, _ record: Record, detail: String) {
        var updated = record
        updated.status = .deleted
        updated.detail = detail
        updated.updatedAt = Date()
        store.set(updated, for: id)
    }
}
