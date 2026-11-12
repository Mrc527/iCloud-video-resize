import AVKit
import SwiftUI
import UIKit
import VideoResizeCore

/// The Library tab: videos that are already in Photos.
struct LibraryScreen: View {
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var importModel: ImportModel  // owns the settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var filter: LibraryFilter = .todo
    @State private var showingSettings = false
    @State private var confirmDelete = false
    @State private var playing: VideoItem?
    @State private var restoring: Set<String> = []

    var body: some View {
        NavigationStack {
            Group {
                switch model.access {
                case .unknown:
                    ProgressView("Waiting for access to Photos…")
                case .denied:
                    LibraryAccessDeniedView()
                case .granted:
                    list
                }
            }
            .navigationTitle("Photos library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .task { await model.load() }
        .onChange(of: filter) { model.selection = [] }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .fullScreenCover(item: $playing) { LibraryPlayer(item: $0) }
        .alert("Photos library", isPresented: messageShown) {
            Button("OK") {}
        } message: {
            Text(model.message ?? "")
        }
        .confirmationDialog(
            "Restore the original of \(restoring.count) video(s)?",
            isPresented: Binding(get: { !restoring.isEmpty }, set: { if !$0 { restoring = [] } }),
            titleVisibility: .visible
        ) {
            Button("Restore originals", role: .destructive) {
                let ids = restoring
                Task { await model.restore(ids) }
            }
        } message: {
            Text("The new smaller videos move to Recently Deleted. The originals leave the album "
                + "\"\(Pipeline.albumTitle)\" and come back to the To do list. "
                + "You will be asked to confirm the deletion once more.")
        }
        .confirmationDialog(
            "Delete \(model.waitingForDeletion) original video(s)?",
            isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Delete originals", role: .destructive) {
                Task { await model.deleteOriginals() }
            }
        } message: {
            Text("The originals move to Recently Deleted and can be recovered for 30 days. "
                + "iPadOS will ask you to confirm once more.")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.appWentToBackground() }
        }
    }

    private var list: some View {
        let rows = model.rows(filter, settings: importModel.settings)
        return List {
            Section {
                LibrarySummary(progress: model.progress)
                    .listRowBackground(Color.clear)
            }
            Section {
                Picker("Show", selection: $filter) {
                    ForEach(LibraryFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }
            Section {
                if model.isScanning && rows.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Reading Photos…").foregroundStyle(.secondary)
                    }
                } else if rows.isEmpty {
                    Text("No videos in this list.").foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    let isSelected = model.selection.contains(row.id)
                    HStack(spacing: 12) {
                        // The circle selects; the rest of the row plays the video.
                        Button {
                            model.toggle(row.id)
                        } label: {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.isRunning)
                        Button {
                            playing = model.items.first { $0.id == row.id }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.name)
                                Text(row.detail).font(.caption).foregroundStyle(.secondary)
                                Text(row.status).font(.caption)
                                    .foregroundStyle(row.isTodo ? Color.accentColor : Color.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .contextMenu {
                        Button {
                            playing = model.items.first { $0.id == row.id }
                        } label: {
                            Label("Play", systemImage: "play")
                        }
                        // On a selected line: all the selected videos, as on the Mac.
                        Button(role: .destructive) {
                            restoring = isSelected ? model.selection : [row.id]
                        } label: {
                            Label("Restore original…", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(model.isRunning || model.isScanning)
                    }
                }
            } header: {
                Text("\(rows.count) video(s)")
            }
        }
    }

    private var messageShown: Binding<Bool> {
        Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                Task { await model.scan() }
            } label: {
                Label("Read again", systemImage: "arrow.clockwise")
            }
            .disabled(model.access != .granted || model.isScanning || model.isRunning)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if model.isRunning {
                Button {
                    model.stop()
                } label: {
                    Label(model.isStopping ? "Stopping" : "Stop", systemImage: "stop.fill")
                }
                .disabled(model.isStopping)
            } else {
                Button {
                    model.start(importModel.settings)
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .disabled(model.access != .granted || model.isScanning
                          || model.chosen(importModel.settings).isEmpty)
            }

            Button {
                confirmDelete = true
            } label: {
                Label("Delete originals", systemImage: "trash")
            }
            .disabled(model.waitingForDeletion == 0 || model.isRunning)

            Button {
                showingSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .disabled(model.isRunning)
        }
    }
}

/// Counts and progress, at the top of the list as in the Mac app.
struct LibrarySummary: View {
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var importModel: ImportModel
    @ObservedObject var progress: ProgressModel

    var body: some View {
        let queue = model.queue(importModel.settings)
        let chosen = model.chosen(importModel.settings)
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)],
                      alignment: .leading, spacing: 10) {
                stat("To do", "\(queue.count)  (\(Format.bytes(size(queue))))")
                if !model.selection.isEmpty {
                    stat("Selected", "\(model.selection.count), \(chosen.count) to do  "
                        + "(\(Format.bytes(size(chosen))))")
                }
                stat("Space saved", Format.bytes(model.savedBytes))
                stat("Originals to delete", "\(model.waitingForDeletion)")
            }
            if let filename = progress.filename {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(progress.phase.rawValue) \(progress.position): \(filename)")
                        .font(.callout)
                        .lineLimit(1)
                    if progress.phase == .downloading || progress.phase == .encoding {
                        ProgressView(value: progress.fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text("Keep the app on screen while it works.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func size(_ videos: [VideoItem]) -> Int64 {
        videos.reduce(0) { $0 + $1.fileSize }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }
    }
}

/// AVKit's player. SwiftUI's VideoPlayer crashed on the Mac: it needs AVKit loaded, and
/// nothing else made the app link AVKit.
struct PlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
    }
}

/// Plays a video of the library. Photos streams it from iCloud when needed.
struct LibraryPlayer: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let item: VideoItem
    @State private var player: AVPlayer?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    PlayerView(player: player).ignoresSafeArea()
                } else if let failure {
                    Text(failure).foregroundStyle(.white).padding()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle(item.filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            do {
                let player = AVPlayer(playerItem: try await model.playerItem(for: item))
                self.player = player
                player.play()
            } catch {
                failure = "Cannot play this video: \(error.localizedDescription)"
            }
        }
        .onDisappear { player?.pause() }
    }
}

struct LibraryAccessDeniedView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
            Text("No full access to Photos").font(.title2)
            Text("To make smaller the videos that are already in your library, the app needs "
                + "full access to Photos. Open Settings and choose Full Access for this app.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}
