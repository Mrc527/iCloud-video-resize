import Foundation
import SwiftUI
import VideoResizeCore

/// Imports videos from an SD card or a folder, as the iPad app does: the videos are first
/// copied to this Mac, so the card can be removed after a few minutes, then each copy is
/// made smaller and added to Photos with everything of the original.
@MainActor
final class CardModel: ObservableObject {
    @Published var folder: URL?
    /// Videos on the card.
    @Published var videos: [SourceVideo] = []
    @Published var unsupported: [String] = []
    @Published var selection: Set<String> = []
    /// Videos copied to this Mac, waiting to be made smaller.
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
    private var worker: Task<Void, Never>?

    init() {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iCloudVideoResize")
        let work = support.appendingPathComponent("import-work")
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

    /// A video counts as done when it is in Photos, made smaller or not.
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

    var savedBytes: Int64 {
        entries.values
            .filter { $0.outcome == .reencoded }
            .reduce(0) { $0 + max($1.originalSize - $1.newSize, 0) }
    }

    // MARK: - Card

    func open(_ url: URL) async {
        closeFolder()
        // Needed only when the folder came from a sandboxed panel; harmless otherwise.
        _ = url.startAccessingSecurityScopedResource()
        folder = url
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
    }

    // MARK: - Import

    func start(_ settings: AppSettings) async {
        guard !isRunning, !isScanning else { return }
        let toCopy = selected
        guard !toCopy.isEmpty || !waiting.isEmpty else { return }

        guard await PhotoKitSink.requestAccess() else {
            message = "The app cannot add videos to Photos. Open System Settings, then Privacy "
                + "& Security, then Photos, and allow this app."
            return
        }
        if let problem = spaceProblem(for: toCopy) {
            message = problem
            return
        }

        isRunning = true
        cardCanBeRemoved = false
        let importer = importer
        let inbox = inbox
        let progress = progress

        worker = Task {
            // Keep the Mac awake while videos are in work.
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Importing videos")
            defer { ProcessInfo.processInfo.endActivity(activity) }

            // Step 1: copy from the card. Fast.
            var copyErrors: [String] = []
            for video in toCopy {
                if Task.isCancelled { break }
                progress.begin(video.filename, phase: .copying)
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try inbox.add(video)
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

            // Step 2: make the copies smaller. Slow, the card is not needed.
            var failures = 0
            for video in inbox.pending {
                if Task.isCancelled { break }
                if self.importedElsewhere(video) {
                    inbox.remove(video.id)
                    self.waiting = inbox.pending
                    continue
                }
                progress.begin(video.filename, phase: .encoding)
                let entry = await importer.importVideo(video, settings: settings) { phase, fraction in
                    Task { @MainActor in progress.update(phase, fraction) }
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
            self.isRunning = false
            self.isStopping = false
            if let first = copyErrors.first {
                self.message = "\(copyErrors.count) video(s) could not be copied from the card. "
                    + "Do not remove the card yet. First error: \(first)"
            } else if failures > 0 {
                self.message = "\(failures) video(s) could not be made smaller. They are still on "
                    + "this Mac. Press Continue to try again, or remove them from the list."
            }
        }
    }

    /// The copies need room on this Mac until they are made smaller.
    private func spaceProblem(for videos: [SourceVideo]) -> String? {
        let values = try? inboxDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        // Room for all the copies, plus the biggest video twice while it is in work.
        let biggest = (videos + waiting).map(\.fileSize).max() ?? 0
        let needed = videos.reduce(0) { $0 + $1.fileSize } + biggest * 2
        guard free < needed else { return nil }
        return "Not enough free space on this Mac: \(Format.bytes(needed)) needed, "
            + "\(Format.bytes(free)) free. Select fewer videos and import in more rounds."
    }

    /// Stop after the current step. A video already being added to Photos is finished first.
    func stop() {
        guard isRunning else { return }
        isStopping = true
        worker?.cancel()
    }
}
