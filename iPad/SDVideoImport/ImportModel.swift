import SwiftUI
import UIKit
import VideoResizeCore

/// Progress of the video in work. Kept apart from `ImportModel` so that the
/// frequent updates redraw only the progress bar, not the whole list.
@MainActor
final class ProgressModel: ObservableObject {
    @Published var filename: String?
    @Published var phase: Phase = .encoding
    @Published var fraction: Double = 0
    @Published var position = ""

    func begin(_ filename: String, position: String) {
        self.filename = filename
        self.position = position
        phase = .encoding
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
final class ImportModel: ObservableObject {
    @Published var settings: AppSettings {
        didSet { settings.save() }
    }
    @Published var folderName: String?
    @Published var videos: [SourceVideo] = []
    @Published var unsupported: [String] = []
    @Published var selection: Set<String> = []
    @Published var entries: [String: ImportEntry] = [:]
    @Published var isScanning = false
    @Published var isRunning = false
    @Published var isStopping = false
    @Published var message: String?

    let progress = ProgressModel()

    private let log: ImportLog
    private let importer: Importer
    private var folder: URL?
    private var worker: Task<Void, Never>?

    init() {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let work = fileManager.temporaryDirectory.appendingPathComponent("import-work")
        try? fileManager.removeItem(at: work)  // leftovers of a previous run
        try? fileManager.createDirectory(at: work, withIntermediateDirectories: true)

        log = ImportLog(url: support.appendingPathComponent("imports.json"))
        importer = Importer(sink: PhotoKitSink(), log: log, workDirectory: work)
        settings = AppSettings.load()
        entries = log.entries
    }

    // MARK: - Derived data

    /// A video counts as done when it is in Photos, re-encoded or not.
    func isDone(_ video: SourceVideo) -> Bool {
        guard let entry = entries[video.id] else { return false }
        return entry.outcome != .failed
    }

    var selected: [SourceVideo] {
        videos.filter { selection.contains($0.id) }
    }

    var selectedBytes: Int64 {
        selected.reduce(0) { $0 + $1.fileSize }
    }

    /// Space saved on this card: what will not be uploaded to iCloud.
    var savedBytes: Int64 {
        videos.compactMap { entries[$0.id] }
            .filter { $0.outcome == .reencoded }
            .reduce(0) { $0 + max($1.originalSize - $1.newSize, 0) }
    }

    // MARK: - Actions

    func open(_ url: URL) async {
        closeFolder()
        guard url.startAccessingSecurityScopedResource() else {
            message = "The app has no permission to read this folder."
            return
        }
        folder = url
        folderName = url.lastPathComponent
        await scan()
    }

    func scan() async {
        guard let folder, !isScanning, !isRunning else { return }
        isScanning = true
        let result = await Task.detached(priority: .userInitiated) {
            SourceScanner.scan(folder: folder)
        }.value
        videos = result.videos
        unsupported = result.unsupported
        entries = log.entries
        selection = Set(result.videos.filter { !isDone($0) }.map(\.id))
        isScanning = false
    }

    func toggle(_ video: SourceVideo) {
        guard !isRunning else { return }
        if selection.contains(video.id) {
            selection.remove(video.id)
        } else {
            selection.insert(video.id)
        }
    }

    func start() async {
        guard !isRunning else { return }
        let queue = selected
        guard !queue.isEmpty else { return }
        guard await PhotoKitSink.requestAccess() else {
            message = "The app cannot add videos to Photos. Open Settings, then Privacy & Security, "
                + "then Photos, and allow this app to add photos."
            return
        }
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true  // keep the screen on
        let settings = settings
        let importer = importer
        let progress = progress

        worker = Task {
            var failures = 0
            for (index, video) in queue.enumerated() {
                if Task.isCancelled { break }
                progress.begin(video.filename, position: "\(index + 1) of \(queue.count)")
                let entry = await importer.importVideo(video, settings: settings) { phase, fraction in
                    Task { @MainActor in progress.update(phase, fraction) }
                }
                self.entries = self.log.entries
                if let entry {
                    if entry.outcome == .failed {
                        failures += 1
                    } else {
                        self.selection.remove(video.id)
                    }
                }
            }
            progress.end()
            UIApplication.shared.isIdleTimerDisabled = false
            self.isRunning = false
            self.isStopping = false
            if failures > 0 {
                self.message = "\(failures) video(s) could not be imported. "
                    + "They are still selected, so you can try again."
            }
        }
    }

    /// Stop after the current step. A video that is already being added to
    /// Photos is finished first.
    func stop() {
        guard isRunning else { return }
        isStopping = true
        worker?.cancel()
    }

    /// iPadOS stops the video encoder when the app is not on screen.
    /// Stopping cleanly keeps the current video for the next run.
    func appWentToBackground() {
        guard isRunning, !isStopping else { return }
        stop()
        message = "The import was paused because the app was closed. "
            + "Keep the app on screen while it works, then press Import again."
    }

    private func closeFolder() {
        folder?.stopAccessingSecurityScopedResource()
        folder = nil
    }
}

enum Format {
    static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
