import SwiftUI
import UIKit
import VideoResizeCore

/// Progress of the video in work. Kept apart from `ImportModel` so that the
/// frequent updates redraw only the progress bar, not the whole list.
@MainActor
final class ProgressModel: ObservableObject {
    @Published var filename: String?
    @Published var phase: Phase = .copying
    @Published var fraction: Double = 0
    @Published var position = ""
    /// True when iOS lets the work go on with the app in the background.
    @Published var canLeave = false

    func begin(_ filename: String, position: String, phase: Phase) {
        self.filename = filename
        self.position = position
        self.phase = phase
        fraction = 0
    }

    func update(_ phase: Phase, _ fraction: Double) {
        self.phase = phase
        self.fraction = fraction
    }

    func end() {
        filename = nil
        canLeave = false
    }
}

/// The import works in two steps, so the card is needed only for a short time:
///
/// 1. Copy the videos from the card to this iPad. This is fast.
/// 2. Re-encode the copies and add them to Photos. This is slow, but the
///    card can already be removed.
@MainActor
final class ImportModel: ObservableObject {
    @Published var settings: AppSettings {
        didSet { settings.save() }
    }
    @Published var folderName: String?
    /// Videos on the card.
    @Published var videos: [SourceVideo] = []
    @Published var unsupported: [String] = []
    @Published var selection: Set<String> = []
    /// Videos copied to this iPad, waiting to be re-encoded.
    @Published var waiting: [SourceVideo] = []
    @Published var entries: [String: ImportEntry] = [:]
    /// The camera of each video on the card, by video id, when the file or its name says it.
    @Published var cameras: [String: String] = [:]
    @Published var isScanning = false
    @Published var isRunning = false
    @Published var isStopping = false
    /// True when every selected video is copied: the card can be removed.
    @Published var cardCanBeRemoved = false
    @Published var message: String?

    let progress = ProgressModel()

    private let log: ImportLog
    private let inbox: Inbox
    private let importer: Importer
    private let inboxDirectory: URL
    /// nil when this build cannot use iCloud.
    private let sync: ImportSync?
    private let deviceID: String
    private var folder: URL?
    private var worker: Task<Void, Never>?
    private let background = BackgroundWork()

    var isSynced: Bool { sync != nil }

    init() {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let work = fileManager.temporaryDirectory.appendingPathComponent("import-work")
        try? fileManager.removeItem(at: work)  // leftovers of a previous run
        try? fileManager.createDirectory(at: work, withIntermediateDirectories: true)

        inboxDirectory = support.appendingPathComponent("inbox")
        inbox = Inbox(directory: inboxDirectory)
        deviceID = Self.loadDeviceID()
        log = ImportLog(url: support.appendingPathComponent("imports.json"), device: deviceID)
        importer = Importer(sink: PhotoKitSink(), log: log, workDirectory: work)
        let cloud = ICloudStore.make()
        if let cloud {
            sync = ImportSync(log: log, shared: cloud)
        } else {
            sync = nil
        }
        settings = AppSettings.load()
        entries = log.entries
        waiting = inbox.pending

        cloud?.observe { [weak self] keys in
            Task { @MainActor in await self?.otherDeviceChanged(keys) }
        }
        Task { await otherDeviceChanged(nil) }
    }

    /// Cards imported on another device: their videos are not selected again.
    private func otherDeviceChanged(_ keys: [String]?) async {
        guard let sync else { return }
        let changed = await Task.detached {
            let changed = sync.pull(keys: keys)
            sync.push()  // puts back what the other device's write to the same key dropped
            return changed
        }.value
        guard changed else { return }
        entries = log.entries
        if !isRunning {
            selection.subtract(videos.filter(isDone).map(\.id))
            for video in inbox.pending where importedElsewhere(video) {
                inbox.remove(video.id)
            }
            waiting = inbox.pending
        }
    }

    /// Identifies this install in the import log shared with the other devices.
    private static func loadDeviceID() -> String {
        if let id = UserDefaults.standard.string(forKey: "deviceID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "deviceID")
        return id
    }

    private func importedElsewhere(_ video: SourceVideo) -> Bool {
        inbox.importedElsewhere(video.id, log: log, device: deviceID)
    }

    // MARK: - Derived data

    /// A video counts as done when it is in Photos, re-encoded or not.
    func isDone(_ video: SourceVideo) -> Bool {
        guard let entry = entries[video.id] else { return false }
        return entry.outcome != .failed
    }

    func isWaiting(_ video: SourceVideo) -> Bool {
        waiting.contains { $0.id == video.id }
    }

    var selected: [SourceVideo] {
        videos.filter { selection.contains($0.id) }
    }

    var selectedBytes: Int64 {
        selected.reduce(0) { $0 + $1.fileSize }
    }

    var waitingBytes: Int64 {
        waiting.reduce(0) { $0 + $1.fileSize }
    }

    /// Space saved so far: what iCloud will not have to upload.
    var savedBytes: Int64 {
        entries.values
            .filter { $0.outcome == .reencoded }
            .reduce(0) { $0 + max($1.originalSize - $1.newSize, 0) }
    }

    // MARK: - Card

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
        cardCanBeRemoved = false
        let result = await Task.detached(priority: .userInitiated) {
            SourceScanner.scan(folder: folder)
        }.value
        // Another card was chosen meanwhile: read that one instead.
        guard self.folder == folder else {
            isScanning = false
            await scan()
            return
        }
        videos = result.videos
        unsupported = result.unsupported
        entries = log.entries
        waiting = inbox.pending
        selection = Set(result.videos.filter { !isDone($0) && !isWaiting($0) }.map(\.id))
        isScanning = false
        cameras = await Task.detached(priority: .utility) { CardCameras.read(result.videos) }.value
    }

    func closeCard() {
        guard !isRunning else { return }
        closeFolder()
        videos = []
        unsupported = []
        selection = []
        cardCanBeRemoved = false
    }

    func toggle(_ video: SourceVideo) {
        guard !isRunning, !isWaiting(video) else { return }
        if selection.contains(video.id) {
            selection.remove(video.id)
        } else {
            selection.insert(video.id)
        }
    }

    /// Delete a local copy that is waiting. The video stays on the card.
    func discard(_ video: SourceVideo) {
        guard !isRunning else { return }
        inbox.remove(video.id)
        waiting = inbox.pending
    }

    private func closeFolder() {
        folder?.stopAccessingSecurityScopedResource()
        folder = nil
        folderName = nil
    }

    // MARK: - Import

    func start() async {
        guard !isRunning else { return }
        let toCopy = selected
        guard !toCopy.isEmpty || !waiting.isEmpty else { return }

        guard await PhotoKitSink.requestAccess() else {
            message = "The app cannot add videos to Photos. Open Settings, then Privacy & Security, "
                + "then Photos, and allow this app to add photos."
            return
        }
        if let problem = spaceProblem(for: toCopy) {
            message = problem
            return
        }

        isRunning = true
        cardCanBeRemoved = false
        UIApplication.shared.isIdleTimerDisabled = true  // keep the screen on
        let settings = settings
        let importer = importer
        let inbox = inbox
        let progress = progress
        let background = background
        let count = toCopy.count + waiting.count
        background.begin(title: "Importing videos", subtitle: "\(count) video(s)",
                         onStart: { progress.canLeave = true },
                         onExpire: { [weak self] in
                             progress.canLeave = false
                             self?.backgroundTimeEnded()
                         })
        // Copying is fast: a tenth of the progress.
        let copyShare = toCopy.isEmpty ? 0.0 : 0.1

        worker = Task {
            // Step 1: copy from the card. Fast.
            var copyErrors: [String] = []
            for (index, video) in toCopy.enumerated() {
                if Task.isCancelled { break }
                let position = "\(index + 1) of \(toCopy.count)"
                progress.begin(video.filename, position: position, phase: .copying)
                let subtitle = "Copying \(position): \(video.filename)"
                let share = { (fraction: Double) in
                    copyShare * (Double(index) + fraction) / Double(toCopy.count)
                }
                background.report(share(0), subtitle: subtitle)
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try inbox.add(video) { fraction in
                            Task { @MainActor in background.report(share(fraction), subtitle: subtitle) }
                        }
                    }.value
                    self.selection.remove(video.id)
                } catch {
                    copyErrors.append("\(video.filename): \(error.localizedDescription)")
                }
                self.waiting = inbox.pending
            }
            if !toCopy.isEmpty, self.selection.isEmpty {
                self.cardCanBeRemoved = true
            }

            // Step 2: re-encode the local copies. Slow, the card is not needed.
            var failures = 0
            let queue = inbox.pending
            for (index, video) in queue.enumerated() {
                if Task.isCancelled { break }
                if self.importedElsewhere(video) {
                    inbox.remove(video.id)
                    self.waiting = inbox.pending
                    continue
                }
                let position = "\(index + 1) of \(queue.count)"
                progress.begin(video.filename, position: position, phase: .encoding)
                let subtitle = "\(position): \(video.filename)"
                let share = { (phase: Phase, fraction: Double) in
                    copyShare + (1 - copyShare)
                        * BackgroundWork.share(index, of: queue.count, phase, fraction)
                }
                background.report(share(.encoding, 0), subtitle: subtitle)
                let entry = await importer.importVideo(video, settings: settings) { phase, fraction in
                    Task { @MainActor in
                        progress.update(phase, fraction)
                        background.report(share(phase, fraction), subtitle: subtitle)
                    }
                }
                if let entry {
                    if entry.outcome == .failed {
                        failures += 1  // the copy stays, so it can be tried again
                    } else {
                        inbox.remove(video.id)
                    }
                    if let sync = self.sync {
                        Task.detached(priority: .utility) { sync.push() }
                    }
                }
                self.entries = self.log.entries
                self.waiting = inbox.pending
            }

            progress.end()
            background.end(success: !Task.isCancelled)
            UIApplication.shared.isIdleTimerDisabled = false
            self.isRunning = false
            self.isStopping = false
            if let first = copyErrors.first {
                self.message = "\(copyErrors.count) video(s) could not be copied from the card. "
                    + "Do not remove the card yet. First error: \(first)"
            } else if failures > 0 {
                self.message = "\(failures) video(s) could not be re-encoded. They are still on "
                    + "this iPad. Press Continue to try again, or swipe to remove them."
            }
        }
    }

    /// The copies need room on this iPad until they are re-encoded.
    private func spaceProblem(for videos: [SourceVideo]) -> String? {
        let values = try? inboxDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        // Room for all the copies, plus the biggest video twice while it is in work.
        let biggest = (videos + waiting).map(\.fileSize).max() ?? 0
        let needed = videos.reduce(0) { $0 + $1.fileSize } + biggest * 2
        guard free < needed else { return nil }
        return "Not enough free space on this iPad: \(Format.bytes(needed)) needed, "
            + "\(Format.bytes(free)) free. Select fewer videos and import in more rounds."
    }

    /// Stop after the current step. A video that is already being added to
    /// Photos is finished first.
    func stop() {
        guard isRunning else { return }
        isStopping = true
        worker?.cancel()
    }

    /// Without a background task from iOS, the video encoder stops when the app is not on screen.
    /// Stopping cleanly keeps the current video for the next run.
    func appWentToBackground() {
        guard isRunning, !isStopping, !background.isActive else { return }
        stop()
        message = "The import was paused because the app was closed. Nothing is lost: "
            + "the videos already copied are on this iPad. Open the app and press Continue."
    }

    /// iOS ended the background time, or the person stopped the work from its progress.
    private func backgroundTimeEnded() {
        guard isRunning, !isStopping else { return }
        stop()
        message = "The import in the background was stopped. Nothing is lost: the videos "
            + "already copied are on this device. Press Continue to go on."
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
