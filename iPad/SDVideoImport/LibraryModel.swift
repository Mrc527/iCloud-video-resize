import SwiftUI
import UIKit
import VideoResizeCore

enum LibraryAccess {
    case unknown, granted, denied
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case todo = "To do"
    case done = "Done"
    case leftAlone = "Left alone"
    case all = "All"

    var id: String { rawValue }
}

/// One line of the library list.
struct LibraryRow: Identifiable {
    let id: String
    let name: String
    let detail: String
    let status: String
    let isTodo: Bool
}

/// Re-encodes the videos that are already in the Photos library.
/// Same steps as the Mac app: download, encode, check, add the new video,
/// park the original in an album. Originals are deleted only on request.
@MainActor
final class LibraryModel: ObservableObject {
    @Published var access: LibraryAccess = .unknown
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
        let work = fileManager.temporaryDirectory.appendingPathComponent("library-work")
        try? fileManager.removeItem(at: work)  // leftovers of a previous run
        try? fileManager.createDirectory(at: work, withIntermediateDirectories: true)

        store = StateStore(url: support.appendingPathComponent("state.json"))
        pipeline = Pipeline(library: library, store: store, workDirectory: work)

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

    /// Videos to process, biggest first: they give the biggest saving.
    func queue(_ settings: AppSettings) -> [VideoItem] {
        let outputs = outputs
        return items
            .filter {
                Policy.decide(item: $0, record: records[$0.id], settings: settings,
                              outputs: outputs) == .process
            }
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

    func rows(_ filter: LibraryFilter, settings: AppSettings) -> [LibraryRow] {
        let outputs = outputs
        return items.compactMap { item in
            let decision = Policy.decide(item: item, record: records[item.id],
                                         settings: settings, outputs: outputs)
            let status: String
            let group: LibraryFilter
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

            var parts = [Format.bytes(item.fileSize), "\(item.width) x \(item.height)",
                         Format.length(item.duration),
                         String(format: "%.1f Mbit/s", item.estimatedBitrate / 1_000_000)]
            if let date = item.creationDate { parts.insert(Format.day.string(from: date), at: 0) }
            return LibraryRow(id: item.id, name: item.filename,
                              detail: parts.joined(separator: "  ·  "),
                              status: status, isTodo: group == .todo)
        }
    }

    // MARK: - Actions

    /// Ask for access to Photos and read the library. Called when the
    /// Library tab is first shown, so the SD card tab alone never asks.
    func load() async {
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

    func start(_ settings: AppSettings) {
        guard !isRunning else { return }
        let videos = queue(settings)
        guard !videos.isEmpty else {
            message = "There is nothing to do."
            return
        }
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true  // keep the screen on
        let pipeline = pipeline
        let progress = progress

        worker = Task {
            for (index, item) in videos.enumerated() {
                if Task.isCancelled { break }
                progress.begin(item.filename, position: "\(index + 1) of \(videos.count)",
                               phase: .downloading)
                await pipeline.process(item, settings: settings) { phase, fraction in
                    Task { @MainActor in progress.update(phase, fraction) }
                }
                self.records = self.store.records
            }
            progress.end()
            UIApplication.shared.isIdleTimerDisabled = false
            self.isRunning = false
            self.isStopping = false
            await self.scan()  // show the new videos
        }
    }

    /// Stop after the current step. A video that is already being added to
    /// Photos is finished first, so nothing is left half done.
    func stop() {
        guard isRunning else { return }
        isStopping = true
        worker?.cancel()
    }

    /// iPadOS stops the video encoder when the app is not on screen.
    func appWentToBackground() {
        guard isRunning, !isStopping else { return }
        stop()
        message = "The work was paused because the app was closed. Nothing is lost. "
            + "Open the app and press Start to continue."
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

extension Format {
    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static func length(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
