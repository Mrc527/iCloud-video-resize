import SwiftUI
import VideoResizeCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter: Filter = .todo
    @State private var confirmDelete = false

    var body: some View {
        Group {
            switch model.access {
            case .unknown:
                ProgressView("Waiting for access to Photos…")
            case .denied:
                AccessDeniedView()
            case .granted:
                VStack(spacing: 0) {
                    SummaryBar()
                    ProgressBar(progress: model.progress)
                    Divider()
                    VideoTable(rows: model.rows(filter))
                }
            }
        }
        .frame(minWidth: 900, minHeight: 480)
        .toolbar { toolbar }
        .task { await model.bootstrap() }
        .alert("iCloud Video Resize", isPresented: messageShown) {
            Button("OK") {}
        } message: {
            Text(model.message ?? "")
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
                    model.start()
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .help("Re-encode the videos in the To do list")
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

    var body: some View {
        let queue = model.queue
        HStack(spacing: 24) {
            stat("Videos", "\(model.items.count)")
            stat("To do", "\(queue.count)  (\(Format.bytes(queue.reduce(0) { $0 + $1.fileSize })))")
            stat("Space saved", Format.bytes(model.savedBytes))
            stat("Originals to delete", "\(model.waitingForDeletion)")
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

    var body: some View {
        Table(rows) {
            TableColumn("Name", value: \.name)
            TableColumn("Date", value: \.date).width(min: 80, ideal: 100)
            TableColumn("Resolution", value: \.resolution).width(min: 80, ideal: 100)
            TableColumn("Length", value: \.length).width(min: 50, ideal: 60)
            TableColumn("Size", value: \.size).width(min: 60, ideal: 80)
            TableColumn("Bit rate", value: \.bitrate).width(min: 80, ideal: 100)
            TableColumn("Status", value: \.status).width(min: 150, ideal: 280)
        }
        .overlay {
            if rows.isEmpty {
                Text("No videos in this list").foregroundStyle(.secondary)
            }
        }
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
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .disabled(model.isRunning)
    }
}
