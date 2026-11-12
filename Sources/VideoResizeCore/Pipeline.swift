import Foundation

public enum Phase: String, Sendable {
    case downloading = "Downloading"
    case copying = "Copying"
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
            if record.status != .replaced, let done = doneElsewhere(item.id) { return done }
            record.attempts = attempts
            store.set(record, for: item.id)
            return record
        } catch {
            // An error after the import started must not be retried blindly:
            // the new video may already be in Photos.
            let current = store.record(for: item.id)
            let importing = current?.status == .importing
            if error is CancellationError && !importing { return nil }
            if !importing, let done = doneElsewhere(item.id) { return done }

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
        do {
            try Carryover.check(source)
        } catch MediaError.unsupported(let what) {
            return Record(status: .skipped, filename: item.filename, originalSize: info.fileSize,
                          detail: "Kept as it is: a new file could not carry \(what)")
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

        let outputDirectory = work.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let destination = outputDirectory.appendingPathComponent(Reencode.outputName(for: source))

        progress(.encoding, 0)
        try await Reencode.run(transcoder, source: source, destination: destination, info: info,
                               quality: settings.quality) { progress(.encoding, $0) }
        try Task.checkCancellation()

        progress(.verifying, 0)
        let output = try await Verifier.verify(source: info, output: destination, original: source,
                                               fullDecode: settings.fullVerify)
        let saving = 100 * (1 - Double(output.fileSize) / Double(max(info.fileSize, 1)))
        if saving < settings.minSavingPercent {
            return Record(status: .notWorth, filename: item.filename, originalSize: info.fileSize,
                          newSize: output.fileSize,
                          detail: String(format: "Saving too small (%.0f%%)", saving))
        }
        try Task.checkCancellation()

        // Another device may have replaced this video while it was encoded here.
        if let done = doneElsewhere(item.id) { return done }

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

    /// The record of a video that another device replaced while this one worked on it.
    /// Policy never starts a replaced video, so such a record came through iCloud.
    private func doneElsewhere(_ id: String) -> Record? {
        guard let current = store.record(for: id), current.status.hasNewVideo else { return nil }
        return current
    }

    private static func transcoder(for settings: AppSettings) throws -> Transcoder {
        switch settings.encoder {
        case .native:
            return NativeTranscoder()
        case .ffmpeg:
            #if os(macOS)
            guard let executable = FFmpegTranscoder.locate(custom: settings.ffmpegPath) else {
                throw MediaError.unsupported("ffmpeg was not found. Install it or use the Apple encoder")
            }
            return FFmpegTranscoder(executable: executable)
            #else
            return NativeTranscoder()  // ffmpeg cannot run on iPad or iPhone
            #endif
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

    /// Undo a replacement: delete the new video and take the original out of the album.
    /// `ids` may name originals or their new videos. Only videos whose new video is on this
    /// device are restored: a new video still on its way through iCloud would stay.
    public func restore(_ ids: Set<String>) async throws -> (restored: Int, notHere: Int) {
        let byNewVideo = Dictionary(store.records.compactMap { id, record in
            record.newIdentifier.map { ($0, id) }
        }, uniquingKeysWith: { first, _ in first })
        let replaced = Set(ids.map { byNewVideo[$0] ?? $0 }).filter {
            store.record(for: $0)?.status == .replaced && library.exists($0)
        }
        // Without its identifier the new video has not reached this device yet. With it but
        // missing, the person deleted it: the original only leaves the album.
        let originals = replaced.filter { store.record(for: $0)?.newIdentifier != nil }
        guard !originals.isEmpty else { return (0, replaced.count) }

        // One confirmation for all the new videos. If the person says no, nothing changes.
        let newVideos = originals.compactMap { store.record(for: $0)?.newIdentifier }
            .filter(library.exists)
        if !newVideos.isEmpty { try await library.delete(newVideos) }

        for id in originals {
            try await library.unpark(original: id, albumTitle: Self.albumTitle)
            guard var record = store.record(for: id) else { continue }
            record.status = .restored
            record.newIdentifier = nil
            record.newSize = nil
            record.detail = "Restored: the new video was deleted"
            record.updatedAt = Date()
            store.set(record, for: id)
        }
        return (originals.count, replaced.count - originals.count)
    }

    private func mark(_ id: String, _ record: Record, detail: String) {
        var updated = record
        updated.status = .deleted
        updated.detail = detail
        updated.updatedAt = Date()
        store.set(updated, for: id)
    }
}
