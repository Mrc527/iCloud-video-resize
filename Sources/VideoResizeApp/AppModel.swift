import AVFoundation
import Foundation
import SwiftUI
import VideoResizeCore

enum Access {
    case unknown, granted, denied
}

enum Filter: String, CaseIterable, Identifiable {
    case todo = "To do"
    case done = "Done"
    case leftAlone = "Left alone"
    case all = "All"

    var id: String { rawValue }
}

/// One line of the table.
struct Row: Identifiable {
    let id: String
    let name: String
    let date: String
    let device: String
    let resolution: String
    let length: String
    let size: String
    let bitrate: String
    let status: String
}

/// Progress of the video in work. Kept apart from `AppModel` so that the
/// frequent updates redraw only the progress bar, not the whole table.
@MainActor
final class ProgressModel: ObservableObject {
    @Published var filename: String?
    @Published var phase: Phase = .downloading
    @Published var fraction: Double = 0

    func begin(_ filename: String, phase: Phase = .downloading) {
        self.filename = filename
        self.phase = phase
        fraction = 0
    }

    func update(_ phase: Phase, _ fraction: Double) {
        self.phase = phase
        self.fraction = fraction
    }

    func end() {
        filename = nil
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings {
        didSet { settings.save() }
    }
    @Published var access: Access = .unknown
    @Published var items: [VideoItem] = []
    @Published var records: [String: Record] = [:]
    @Published var isScanning = false
    @Published var isRunning = false
    @Published var isStopping = false
    @Published var message: String?

    let progress = ProgressModel()

    private let store: StateStore
    private let library = PhotoKitLibrary()
    private let pipeline: Pipeline
    /// nil when this build cannot use iCloud: it is not signed with a team.
    private let sync: RecordSync?
    private var worker: Task<Void, Never>?
    private let cameras: CameraCache
    private var cameraReader: Task<Void, Never>?
    /// Changes when camera names were read, so that the table shows them.
    @Published private var camerasRead = 0

    var isSynced: Bool { sync != nil }

    init() {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iCloudVideoResize")
        let work = support.appendingPathComponent("work")
        try? fileManager.removeItem(at: work)  // leftovers of a previous run
        try? fileManager.createDirectory(at: work, withIntermediateDirectories: true)

        store = StateStore(url: support.appendingPathComponent("state.json"))
        pipeline = Pipeline(library: library, store: store, workDirectory: work)
        cameras = CameraCache(url: support.appendingPathComponent("cameras.json"))
        let cloud = ICloudStore.make()
        if let cloud {
            sync = RecordSync(store: store, shared: cloud, identifiers: library)
        } else {
            sync = nil
        }
        settings = AppSettings.load()

        let interrupted = store.recoverInterrupted()
        records = store.records
        if interrupted > 0 {
            message = "\(interrupted) video(s) were being added to Photos when the app stopped. "
                + "Look in Photos for duplicates. They are listed under \"Left alone\"."
        }
        cloud?.observe { [weak self] keys in
            Task { @MainActor in await self?.otherDeviceChanged(keys) }
        }
    }

    // MARK: - Derived data

    private var outputs: Set<String> {
        Set(records.values.compactMap(\.newIdentifier))
    }

    private func decision(for item: VideoItem, outputs: Set<String>) -> Decision {
        Policy.decide(item: item, record: records[item.id], settings: settings, outputs: outputs)
    }

    /// Videos to process, biggest first: they give the biggest saving.
    var queue: [VideoItem] {
        let outputs = outputs
        return items
            .filter { decision(for: $0, outputs: outputs) == .process }
            .sorted { $0.fileSize > $1.fileSize }
    }

    var waitingForDeletion: Int {
        records.values.filter { $0.status == .replaced }.count
    }

    /// New videos of Shared Library originals that wait in the album to be moved there by hand.
    var waitingToMove: Int {
        let inShared = Set(items.filter { $0.inSharedLibrary == true }.map(\.id))
        let notShared = Set(items.filter { $0.inSharedLibrary == false }.map(\.id))
        return records.filter { id, record in
            record.status == .replaced && inShared.contains(id)
                && record.newIdentifier.map(notShared.contains) == true
        }.count
    }

    var savedBytes: Int64 {
        records.values
            .filter { $0.status == .replaced || $0.status == .deleted }
            .reduce(0) { $0 + max(($1.originalSize ?? 0) - ($1.newSize ?? 0), 0) }
    }

    func rows(_ filter: Filter) -> [Row] {
        let outputs = outputs
        return items.compactMap { item in
            let decision = decision(for: item, outputs: outputs)
            let status: String
            let group: Filter
            switch decision {
            case .process:
                status = "To do"
                group = .todo
            case .leave(let reason):
                status = reason
                let isDone = outputs.contains(item.id) || records[item.id]?.status == .replaced
                group = isDone ? .done : .leftAlone
            }
            guard filter == .all || filter == group else { return nil }
            return Row(
                id: item.id,
                name: item.filename,
                date: item.creationDate.map { Format.date.string(from: $0) } ?? "",
                device: item.device ?? cameraName(for: item) ?? "",
                resolution: "\(item.width) x \(item.height)",
                length: Format.length(item.duration),
                size: Format.bytes(item.fileSize),
                bitrate: String(format: "%.1f Mbit/s", item.estimatedBitrate / 1_000_000),
                status: status)
        }
    }

    // MARK: - Actions

    func bootstrap() async {
        guard access == .unknown else { return }
        access = await PhotoKitLibrary.requestAccess() ? .granted : .denied
        if access == .granted { await scan() }
    }

    func scan() async {
        guard access == .granted, !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            items = try await library.listVideos()
            readCameraNames()
            if let sync {
                await Task.detached { sync.pull(); sync.push() }.value
            }
            records = store.records
        } catch {
            message = "Cannot read the Photos library: \(error.localizedDescription)"
            return
        }
        await gatherVideosToMove()
    }

    /// Also gathers the new videos made before the album of the videos to move existed.
    private func gatherVideosToMove() async {
        let note: String
        do {
            let added = try await pipeline.gatherVideosToMove()
            guard added > 0 else { return }
            note = "\(added) new video(s) added to the album \"\(Pipeline.moveAlbumTitle)\": "
                + "their original is in the Shared Library. In Photos, move them there."
        } catch {
            note = "Could not add videos to the album \"\(Pipeline.moveAlbumTitle)\": "
                + error.localizedDescription
        }
        message = [message, note].compactMap { $0 }.joined(separator: "\n\n")
    }

    /// Photos knows the camera only from Apple's tags. For the other videos it is read from
    /// the file when the original is on this Mac, else guessed from the name.
    private func cameraName(for item: VideoItem) -> String? {
        if let name = cameras.name(for: item.id), !name.isEmpty { return name }
        return CameraName.fromName(item.filename)
    }

    private func readCameraNames() {
        cameraReader?.cancel()
        let toRead = items.filter { $0.device == nil && cameras.name(for: $0.id) == nil }.map(\.id)
        guard !toRead.isEmpty else { return }
        let library = library
        let cache = cameras
        cameraReader = Task {
            for start in stride(from: 0, to: toRead.count, by: 20) {
                if Task.isCancelled { return }
                let found = await library.cameraNames(Array(toRead[start..<min(start + 20, toRead.count)]))
                cache.merge(found)
                if found.values.contains(where: { !$0.isEmpty }) { self.camerasRead += 1 }
            }
        }
    }

    /// Another device changed the shared records.
    private func otherDeviceChanged(_ keys: [String]) async {
        guard let sync, access == .granted else { return }
        let changed = await Task.detached {
            let changed = sync.pull(keys: keys)
            sync.push()  // puts back what the other device's write to the same key dropped
            return changed
        }.value
        if changed { records = store.records }
    }

    private func pushRecords() {
        guard let sync else { return }
        Task.detached(priority: .utility) { sync.push() }
    }

    func playerItem(for item: VideoItem) async throws -> AVPlayerItem {
        try await library.playerItem(for: item.id)
    }

    /// Re-encode the videos of the To do list. With `only`, just those of them.
    func start(only ids: Set<String> = []) {
        // While scanning, the records from the other devices may not be merged yet.
        guard !isRunning, !isScanning else { return }
        if settings.encoder == .ffmpeg, FFmpegTranscoder.locate(custom: settings.ffmpegPath) == nil {
            message = "ffmpeg was not found. Install it with \"brew install ffmpeg\", "
                + "or choose the Apple encoder in Settings."
            return
        }
        let videos = ids.isEmpty ? queue : queue.filter { ids.contains($0.id) }
        guard !videos.isEmpty else {
            message = ids.isEmpty
                ? "There is nothing to do."
                : "None of the selected videos is in the To do list."
            return
        }
        isRunning = true
        let settings = settings
        let pipeline = pipeline
        let progress = progress

        worker = Task {
            // Keep the Mac awake while videos are in work.
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Re-encoding videos")
            defer { ProcessInfo.processInfo.endActivity(activity) }

            for item in videos {
                if Task.isCancelled { break }
                // Another device may have done it since the list was made.
                guard self.decision(for: item, outputs: self.outputs) == .process else { continue }
                progress.begin(item.filename)
                await pipeline.process(item, settings: settings) { phase, fraction in
                    Task { @MainActor in progress.update(phase, fraction) }
                }
                self.records = self.store.records
                self.pushRecords()
            }
            progress.end()
            self.isRunning = false
            self.isStopping = false
            await self.scan()  // show the new videos
        }
    }

    /// Stop after the current step. A video that is already being added to
    /// Photos is finished first, so nothing is left half done.
    func stop() {
        isStopping = true
        worker?.cancel()
    }

    /// Delete the new videos and bring back the originals. `ids` may name either.
    func restore(_ ids: Set<String>) async {
        guard !isRunning else { return }
        do {
            let result = try await pipeline.restore(ids)
            var text = result.restored == 0 && result.notHere == 0
                ? "None of the selected videos was replaced by this app."
                : "\(result.restored) original(s) restored. The new videos are in Recently Deleted."
            if result.notHere > 0 {
                text += " \(result.notHere) not restored: their new video is not on this Mac "
                    + "(iCloud may still be bringing it). Try again later."
            }
            message = text
        } catch {
            message = "The restore stopped: \(error.localizedDescription)"
        }
        records = store.records
        pushRecords()
        await scan()
    }

    func deleteOriginals() async {
        defer { pushRecords() }
        do {
            let result = try await pipeline.deleteOriginals()
            records = store.records
            await scan()
            var text = "\(result.deleted) original(s) moved to Recently Deleted."
            if result.heldBack > 0 {
                text += " \(result.heldBack) kept, because the new video was not found in Photos."
            }
            if result.notMoved > 0 {
                text += " \(result.notMoved) kept, because they are in the Shared Library and their "
                    + "new video is not there yet. In Photos, move the videos of the album "
                    + "\"\(Pipeline.moveAlbumTitle)\" to the Shared Library, then delete again."
            }
            message = text
        } catch {
            records = store.records
            message = "Nothing was deleted: \(error.localizedDescription)"
        }
    }
}

enum Format {
    static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func length(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
