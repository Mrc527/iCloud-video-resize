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

    func begin(_ filename: String) {
        self.filename = filename
        phase = .downloading
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
    private var worker: Task<Void, Never>?

    init() {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iCloudVideoResize")
        let work = support.appendingPathComponent("work")
        try? fileManager.removeItem(at: work)  // leftovers of a previous run
        try? fileManager.createDirectory(at: work, withIntermediateDirectories: true)

        store = StateStore(url: support.appendingPathComponent("state.json"))
        pipeline = Pipeline(library: library, store: store, workDirectory: work)
        settings = AppSettings.load()

        let interrupted = store.recoverInterrupted()
        records = store.records
        if interrupted > 0 {
            message = "\(interrupted) video(s) were being added to Photos when the app stopped. "
                + "Look in Photos for duplicates. They are listed under \"Left alone\"."
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
            records = store.records
        } catch {
            message = "Cannot read the Photos library: \(error.localizedDescription)"
        }
    }

    func start() {
        guard !isRunning else { return }
        if settings.encoder == .ffmpeg, FFmpegTranscoder.locate(custom: settings.ffmpegPath) == nil {
            message = "ffmpeg was not found. Install it with \"brew install ffmpeg\", "
                + "or choose the Apple encoder in Settings."
            return
        }
        let videos = queue
        guard !videos.isEmpty else {
            message = "There is nothing to do."
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
                progress.begin(item.filename)
                await pipeline.process(item, settings: settings) { phase, fraction in
                    Task { @MainActor in progress.update(phase, fraction) }
                }
                self.records = self.store.records
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

    func deleteOriginals() async {
        do {
            let result = try await pipeline.deleteOriginals()
            records = store.records
            await scan()
            var text = "\(result.deleted) original(s) moved to Recently Deleted."
            if result.heldBack > 0 {
                text += " \(result.heldBack) kept, because the new video was not found in Photos."
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
