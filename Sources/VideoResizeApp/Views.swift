import AVKit
import SwiftUI
import VideoResizeCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter: Filter = .todo
    @State private var confirmDelete = false
    @State private var selection = Set<String>()
    @State private var playing: VideoItem?
    @State private var restoring: Set<String> = []

    var body: some View {
        Group {
            switch model.access {
            case .unknown:
                ProgressView("Waiting for access to Photos…")
            case .denied:
                AccessDeniedView()
            case .granted:
                VStack(spacing: 0) {
                    SummaryBar(selection: selection)
                    ProgressBar(progress: model.progress)
                    Divider()
                    VideoTable(rows: model.rows(filter), selection: $selection,
                               play: { id in playing = model.items.first { $0.id == id } },
                               encode: { model.start(only: $0) },
                               restore: { restoring = $0 },
                               canChange: !model.isScanning && !model.isRunning)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 480)
        .toolbar { toolbar }
        .onChange(of: filter) { selection = [] }
        .onChange(of: model.isScanning) {
            // After each scan, also the one that ends a run: keep only what is still to do.
            if !model.isScanning && !model.isRunning {
                selection.formIntersection(model.queue.map(\.id))
            }
        }
        .sheet(item: $playing) { PlayerSheet(item: $0) }
        .task { await model.bootstrap() }
        .alert("iCloud Video Resize", isPresented: messageShown) {
            Button("OK") {}
        } message: {
            Text(model.message ?? "")
        }
        .confirmationDialog(
            "Restore the original of the selected video(s)?",
            isPresented: Binding(get: { !restoring.isEmpty }, set: { if !$0 { restoring = [] } })
        ) {
            Button("Restore originals", role: .destructive) {
                let ids = restoring
                Task { await model.restore(ids) }
            }
        } message: {
            Text("The new smaller videos move to Recently Deleted. The originals leave the album "
                + "\"\(Pipeline.albumTitle)\" and come back to the To do list. "
                + "macOS will ask you to confirm the deletion once more.")
        }
        .confirmationDialog(
            "Delete \(model.waitingForDeletion) original video(s)?",
            isPresented: $confirmDelete
        ) {
            Button("Delete originals", role: .destructive) {
                Task { await model.deleteOriginals() }
            }
        } message: {
            Text("The originals move to Recently Deleted and can be recovered for 30 days. "
                + (model.waitingToMove > 0 ? "Originals in the Shared Library stay until their new video is moved there. " : "")
                + "macOS will ask you to confirm once more.")
        }
    }

    private var messageShown: Binding<Bool> {
        Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        ToolbarItemGroup {
            Button {
                Task { await model.scan() }
            } label: {
                Label("Scan", systemImage: "arrow.clockwise")
            }
            .help("Read the Photos library again")
            .disabled(model.access != .granted || model.isScanning || model.isRunning)

            if model.isRunning {
                Button {
                    model.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Stop after the current step")
                .disabled(model.isStopping)
            } else {
                Button {
                    model.start(only: selection)
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .help(selection.isEmpty
                      ? "Re-encode all the videos in the To do list"
                      : "Re-encode the selected videos that are in the To do list")
                .disabled(model.access != .granted || model.isScanning)
            }

            Button {
                confirmDelete = true
            } label: {
                Label("Delete originals", systemImage: "trash")
            }
            .help("Delete the originals that were replaced")
            .disabled(model.waitingForDeletion == 0 || model.isRunning)

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }
}

struct SummaryBar: View {
    @EnvironmentObject private var model: AppModel
    let selection: Set<String>

    var body: some View {
        let queue = model.queue
        HStack(spacing: 24) {
            stat("Videos", "\(model.items.count)")
            stat("To do", "\(queue.count)  (\(Format.bytes(queue.reduce(0) { $0 + $1.fileSize })))")
            if !selection.isEmpty {
                let chosen = queue.filter { selection.contains($0.id) }
                stat("Selected", "\(selection.count), \(chosen.count) to do  "
                    + "(\(Format.bytes(chosen.reduce(0) { $0 + $1.fileSize })))")
            }
            stat("Space saved", Format.bytes(model.savedBytes))
            stat("Originals to delete", "\(model.waitingForDeletion)")
            if model.waitingToMove > 0 {
                stat("To move to Shared Library", "\(model.waitingToMove)")
                    .help("In Photos, move the videos of the album \"\(Pipeline.moveAlbumTitle)\" "
                        + "to the Shared Library. Until then their originals are not deleted.")
            }
            Spacer()
            if model.isScanning {
                ProgressView().controlSize(.small)
                Text("Reading Photos…").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }
    }
}

struct ProgressBar: View {
    @ObservedObject var progress: ProgressModel

    var body: some View {
        if let filename = progress.filename {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(progress.phase.rawValue): \(filename)")
                    .font(.callout)
                    .lineLimit(1)
                // Checking and adding to Photos give no percentage.
                if progress.phase == .downloading || progress.phase == .encoding {
                    ProgressView(value: progress.fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }
}

struct VideoTable: View {
    let rows: [Row]
    @Binding var selection: Set<String>
    let play: (String) -> Void
    let encode: (Set<String>) -> Void
    let restore: (Set<String>) -> Void
    /// False while scanning or working.
    let canChange: Bool

    var body: some View {
        Table(rows, selection: $selection) {
            TableColumn("Name", value: \.name)
            TableColumn("Date", value: \.date).width(min: 80, ideal: 100)
            TableColumn("Device", value: \.device).width(min: 80, ideal: 140)
            TableColumn("Resolution", value: \.resolution).width(min: 80, ideal: 100)
            TableColumn("Length", value: \.length).width(min: 50, ideal: 60)
            TableColumn("Size", value: \.size).width(min: 60, ideal: 80)
            TableColumn("Bit rate", value: \.bitrate).width(min: 80, ideal: 100)
            TableColumn("Status", value: \.status).width(min: 150, ideal: 280)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Play") { ids.first.map(play) }
                .disabled(ids.count != 1)
            Button("Re-encode") { encode(ids) }
                .disabled(ids.isEmpty || !canChange)
            Button("Restore original…") { restore(ids) }
                .disabled(ids.isEmpty || !canChange)
        } primaryAction: { ids in
            // Double click.
            if ids.count == 1 { ids.first.map(play) }
        }
        .overlay {
            if rows.isEmpty {
                Text("No videos in this list").foregroundStyle(.secondary)
            }
        }
    }
}

/// AVKit's player view. SwiftUI's VideoPlayer crashed: it needs AVKit loaded, and
/// nothing else made the app link AVKit.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }
}

/// Plays a video of the library. Photos streams it from iCloud when needed.
struct PlayerSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let item: VideoItem
    @State private var player: AVPlayer?
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let player {
                    PlayerView(player: player)
                } else if let failure {
                    Text(failure).foregroundStyle(.white)
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(minWidth: 800, idealWidth: 960, minHeight: 450, idealHeight: 540)
            HStack {
                Text(item.filename).font(.headline)
                if let device = item.device {
                    Text(device).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
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

struct AccessDeniedView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
            Text("No access to Photos").font(.title2)
            Text("Open System Settings, then Privacy & Security, then Photos, "
                + "and give this app full access. Then open the app again.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Button("Open System Settings") {
                let link = "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos"
                if let url = URL(string: link) { NSWorkspace.shared.open(url) }
            }
        }
        .padding(40)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Encoding") {
                Picker("Encoder", selection: $model.settings.encoder) {
                    ForEach(EncoderKind.allCases) { Text($0.title).tag($0) }
                }
                Picker("Quality", selection: $model.settings.quality) {
                    ForEach(Quality.allCases) { Text($0.title).tag($0) }
                }
                if model.settings.encoder == .ffmpeg {
                    TextField("ffmpeg path", text: $model.settings.ffmpegPath,
                              prompt: Text("Found automatically"))
                    if FFmpegTranscoder.locate(custom: model.settings.ffmpegPath) == nil {
                        Text("ffmpeg was not found. Install it with: brew install ffmpeg")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
            }
            Section("Which videos") {
                TextField("Minimum size (MB)", value: $model.settings.minSizeMB, format: .number)
                Stepper("Minimum age: \(model.settings.minAgeDays) days",
                        value: $model.settings.minAgeDays, in: 0...3650)
                TextField("Minimum saving (%)", value: $model.settings.minSavingPercent,
                          format: .number)
            }
            Section("Safety") {
                Toggle("Decode the whole new video before using it",
                       isOn: $model.settings.fullVerify)
            }
            Section("Other devices") {
                Text(model.isSynced
                     ? "What this app did is shared through iCloud with your iPad and iPhone."
                     : "Not shared with your other devices: this build is not signed with a team.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .disabled(model.isRunning)
    }
}
