import SwiftUI
import UniformTypeIdentifiers
import VideoResizeCore

/// The SD card tab: videos are made smaller before they go into Photos.
struct CardView: View {
    @EnvironmentObject private var card: CardModel
    @EnvironmentObject private var model: AppModel  // owns the settings
    @State private var picking = false

    var body: some View {
        VStack(spacing: 0) {
            CardSummary()
            ProgressBar(progress: card.progress)
            Divider()
            if card.folder == nil && card.waiting.isEmpty {
                welcome
            } else {
                list
            }
        }
        .frame(minWidth: 900, minHeight: 480)
        .toolbar { toolbar }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                Task { await card.open(url) }
            }
        }
        .alert("SD card", isPresented: messageShown) {
            Button("OK") {}
        } message: {
            Text(card.message ?? "")
        }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "sdcard").font(.system(size: 56)).foregroundStyle(.secondary)
            Text("Import videos from an SD card").font(.title2)
            Text("The app first copies the videos to this Mac, so you can remove the card after "
                + "a few minutes. Then it makes each video smaller, with all its data, before it "
                + "goes into Photos, so iCloud has less to upload. The card is never changed.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            Button("Choose card or folder…") { picking = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            if card.cardCanBeRemoved {
                Label("All the videos are copied. You can remove the card now.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if !card.waiting.isEmpty {
                Section("On this Mac, waiting to be made smaller") {
                    ForEach(card.waiting) { video in
                        HStack {
                            Image(systemName: "clock").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(video.filename)
                                Text(subtitle(video, camera: card.cameras[video.id])).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let entry = card.entries[video.id], entry.outcome == .failed {
                                EntryStatus(entry: entry)
                            }
                            Button("Remove") { card.discard(video) }
                                .disabled(card.isRunning)
                                .help("Delete the copy on this Mac. The video stays on the card.")
                        }
                    }
                }
            }
            if let folder = card.folder {
                Section {
                    if card.isScanning {
                        HStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text("Reading the card…").foregroundStyle(.secondary)
                        }
                    } else if card.videos.isEmpty {
                        Text("No videos found in this folder.").foregroundStyle(.secondary)
                    }
                    ForEach(card.videos) { video in
                        CardLine(video: video)
                    }
                } header: {
                    Text("On the card: \(folder.lastPathComponent)")
                } footer: {
                    if !card.unsupported.isEmpty {
                        Text("\(card.unsupported.count) file(s) are in a format this Mac cannot "
                            + "read (for example AVCHD or MXF) and are not listed: "
                            + card.unsupported.prefix(5).joined(separator: ", ")
                            + (card.unsupported.count > 5 ? "…" : ""))
                    }
                }
            }
        }
    }

    private var messageShown: Binding<Bool> {
        Binding(get: { card.message != nil }, set: { if !$0 { card.message = nil } })
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                picking = true
            } label: {
                Label("Choose card", systemImage: "sdcard")
            }
            .help("Choose an SD card or a folder")
            .disabled(card.isRunning || card.isScanning)

            Button {
                Task { await card.scan() }
            } label: {
                Label("Read again", systemImage: "arrow.clockwise")
            }
            .disabled(card.folder == nil || card.isRunning || card.isScanning)

            if card.isRunning {
                Button {
                    card.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Stop after the current step")
                .disabled(card.isStopping)
            } else {
                Button {
                    Task { await card.start(model.settings) }
                } label: {
                    Label("Import", systemImage: "play.fill")
                }
                .help("Copy the selected videos, then make them smaller and add them to Photos")
                .disabled((card.selection.isEmpty && card.waiting.isEmpty) || card.isScanning)
            }

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }
}

struct CardSummary: View {
    @EnvironmentObject private var card: CardModel

    var body: some View {
        let selected = card.selected
        HStack(spacing: 24) {
            stat("On the card", "\(card.videos.count)")
            stat("To import", "\(selected.count)  (\(Format.bytes(selected.reduce(0) { $0 + $1.fileSize })))")
            stat("Waiting on this Mac", "\(card.waiting.count)  "
                + "(\(Format.bytes(card.waiting.reduce(0) { $0 + $1.fileSize })))")
            stat("Space saved", Format.bytes(card.savedBytes))
            Spacer()
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

/// A video on the card. The box selects it for the import.
struct CardLine: View {
    @EnvironmentObject private var card: CardModel
    let video: SourceVideo

    var body: some View {
        let isWaiting = card.isWaiting(video)
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { card.selection.contains(video.id) },
                                     set: { _ in card.toggle(video) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(card.isRunning || isWaiting)
            VStack(alignment: .leading, spacing: 2) {
                Text(video.filename)
                Text(subtitle(video, camera: card.cameras[video.id])).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isWaiting {
                Label("Copied to this Mac", systemImage: "arrow.down.doc")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let entry = card.entries[video.id] {
                EntryStatus(entry: entry)
            }
        }
    }
}

struct EntryStatus: View {
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
        .frame(maxWidth: 360, alignment: .trailing)
    }
}

private func subtitle(_ video: SourceVideo, camera: String?) -> String {
    var parts = [Format.bytes(video.fileSize)]
    if let camera { parts.insert(camera, at: 0) }
    if let date = video.modified { parts.append(Format.dateTime.string(from: date)) }
    return parts.joined(separator: "  ·  ")
}
