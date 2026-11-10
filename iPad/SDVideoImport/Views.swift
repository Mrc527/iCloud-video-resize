import SwiftUI
import UniformTypeIdentifiers
import VideoResizeCore

struct ContentView: View {
    @EnvironmentObject private var model: ImportModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var pickingFolder = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if model.folderName == nil && model.waiting.isEmpty {
                    WelcomeView { pickingFolder = true }
                } else {
                    VideoList()
                }
            }
            .navigationTitle(model.folderName ?? "SD Video Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) { BottomBar(progress: model.progress) }
        }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                Task { await model.open(url) }
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .alert("SD Video Import", isPresented: messageShown) {
            Button("OK") {}
        } message: {
            Text(model.message ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.appWentToBackground() }
        }
    }

    private var messageShown: Binding<Bool> {
        Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                pickingFolder = true
            } label: {
                Label("Choose card", systemImage: "sdcard")
            }
            .disabled(model.isRunning)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                Task { await model.scan() }
            } label: {
                Label("Read again", systemImage: "arrow.clockwise")
            }
            .disabled(model.folderName == nil || model.isRunning || model.isScanning)

            Button {
                showingSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .disabled(model.isRunning)
        }
    }
}

struct WelcomeView: View {
    let choose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sdcard").font(.system(size: 56)).foregroundStyle(.secondary)
            Text("Import videos from an SD card").font(.title2)
            Text("The app first copies the videos to this iPad, so you can remove the card "
                + "after a few minutes. Then it makes each video smaller before it goes "
                + "into Photos, so iCloud has less to upload. The card is never changed.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            Button("Choose card or folder", action: choose)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(32)
    }
}

struct VideoList: View {
    @EnvironmentObject private var model: ImportModel

    var body: some View {
        List {
            if model.cardCanBeRemoved {
                Label("All the videos are copied. You can remove the card now.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            if !model.waiting.isEmpty {
                Section {
                    ForEach(model.waiting) { video in
                        WaitingRow(video: video)
                    }
                } header: {
                    Text("On this iPad, waiting")
                } footer: {
                    Text("These videos are copied from the card. The card is not needed for them.")
                }
            }

            if model.folderName != nil {
                Section {
                    if model.isScanning {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Reading the card…").foregroundStyle(.secondary)
                        }
                    } else if model.videos.isEmpty {
                        Text("No videos found in this folder.").foregroundStyle(.secondary)
                    }
                    ForEach(model.videos) { video in
                        CardRow(video: video)
                    }
                } header: {
                    Text("On the card")
                } footer: {
                    if !model.unsupported.isEmpty {
                        Text("\(model.unsupported.count) file(s) are in a format this iPad cannot "
                            + "read (for example AVCHD or MXF) and are not listed: "
                            + model.unsupported.prefix(5).joined(separator: ", ")
                            + (model.unsupported.count > 5 ? "…" : ""))
                    }
                }
            }
        }
    }
}

private func subtitle(_ video: SourceVideo) -> String {
    var parts = [Format.bytes(video.fileSize)]
    if let date = video.modified { parts.append(Format.date.string(from: date)) }
    return parts.joined(separator: "  ·  ")
}

/// A video on the card. Tap to select it.
struct CardRow: View {
    @EnvironmentObject private var model: ImportModel
    let video: SourceVideo

    var body: some View {
        let entry = model.entries[video.id]
        let isWaiting = model.isWaiting(video)
        let isSelected = model.selection.contains(video.id)
        Button {
            model.toggle(video)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .opacity(isWaiting ? 0.3 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.filename).foregroundStyle(.primary)
                    Text(subtitle(video)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isWaiting {
                    Label("Copied to this iPad", systemImage: "ipad.and.arrow.forward")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let entry {
                    StatusLabel(entry: entry)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isRunning || isWaiting)
    }
}

/// A video already copied to this iPad. Swipe to remove the copy.
struct WaitingRow: View {
    @EnvironmentObject private var model: ImportModel
    let video: SourceVideo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock").font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(video.filename)
                Text(subtitle(video)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let entry = model.entries[video.id], entry.outcome == .failed {
                StatusLabel(entry: entry)
            }
        }
        .swipeActions {
            Button("Remove", role: .destructive) {
                model.discard(video)
            }
            .disabled(model.isRunning)
        }
    }
}

struct StatusLabel: View {
    let entry: ImportEntry

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            switch entry.outcome {
            case .reencoded:
                Label("In Photos", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                Text("\(Format.bytes(entry.newSize)). \(entry.detail)")
            case .original:
                Label("In Photos", systemImage: "checkmark.seal").foregroundStyle(.green)
                Text(entry.detail)
            case .failed:
                Label("Failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(entry.detail)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: 320, alignment: .trailing)
    }
}

/// Progress of the current video and the Import button.
struct BottomBar: View {
    @EnvironmentObject private var model: ImportModel
    @ObservedObject var progress: ProgressModel

    var body: some View {
        if model.folderName != nil || !model.waiting.isEmpty {
            VStack(spacing: 10) {
                if let filename = progress.filename {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(progress.phase.rawValue) \(progress.position): \(filename)")
                            .font(.callout)
                            .lineLimit(1)
                        if progress.phase == .encoding {
                            ProgressView(value: progress.fraction)
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                        Text(progress.phase == .copying && !model.cardCanBeRemoved
                             ? "Copying from the card. Do not remove it yet."
                             : "Keep the app on screen while it works.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    if model.savedBytes > 0 {
                        Text("Saved so far: \(Format.bytes(model.savedBytes))")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isRunning {
                        Button(model.isStopping ? "Stopping…" : "Stop", role: .destructive) {
                            model.stop()
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isStopping)
                    } else {
                        Button(startTitle) {
                            Task { await model.start() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled((model.selection.isEmpty && model.waiting.isEmpty)
                                  || model.isScanning)
                    }
                }
            }
            .padding()
            .background(.bar)
        }
    }

    private var startTitle: String {
        if model.selection.isEmpty {
            return "Continue: \(model.waiting.count) video(s) waiting, "
                + Format.bytes(model.waitingBytes)
        }
        return "Import \(model.selection.count) video(s), " + Format.bytes(model.selectedBytes)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: ImportModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Quality", selection: $model.settings.quality) {
                        ForEach(Quality.allCases) { Text($0.title).tag($0) }
                    }
                } footer: {
                    Text("Balanced gives about 5 Mbit/s for 1080p and 14 Mbit/s for 4K, at 30 fps.")
                }
                Section {
                    Stepper("Minimum saving: \(Int(model.settings.minSavingPercent))%",
                            value: $model.settings.minSavingPercent, in: 0...90, step: 5)
                } footer: {
                    Text("A video that would not get at least this much smaller is added as it is.")
                }
                Section {
                    Toggle("Check every frame of the new video",
                           isOn: $model.settings.fullVerify)
                } footer: {
                    Text("Slower, but a damaged video is never added to Photos.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
