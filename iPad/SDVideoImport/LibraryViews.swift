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
            .safeAreaInset(edge: .bottom) {
                if model.access == .granted {
                    LibraryBottomBar(progress: model.progress) { confirmDelete = true }
                }
            }
        }
        .task { await model.load() }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .alert("Photos library", isPresented: messageShown) {
            Button("OK") {}
        } message: {
            Text(model.message ?? "")
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
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.name)
                        Text(row.detail).font(.caption).foregroundStyle(.secondary)
                        Text(row.status).font(.caption)
                            .foregroundStyle(row.isTodo ? Color.accentColor : Color.secondary)
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
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                Task { await model.scan() }
            } label: {
                Label("Read again", systemImage: "arrow.clockwise")
            }
            .disabled(model.access != .granted || model.isScanning || model.isRunning)

            Button {
                showingSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .disabled(model.isRunning)
        }
    }
}

struct LibraryBottomBar: View {
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var importModel: ImportModel
    @ObservedObject var progress: ProgressModel
    let askDelete: () -> Void

    var body: some View {
        let queue = model.queue(importModel.settings)
        VStack(spacing: 10) {
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
            HStack {
                if model.savedBytes > 0 {
                    Text("Saved: \(Format.bytes(model.savedBytes))")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.waitingForDeletion > 0 {
                    Button("Delete \(model.waitingForDeletion) original(s)", role: .destructive,
                           action: askDelete)
                        .buttonStyle(.bordered)
                        .disabled(model.isRunning)
                }
                if model.isRunning {
                    Button(model.isStopping ? "Stopping…" : "Stop", role: .destructive) {
                        model.stop()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isStopping)
                } else {
                    Button("Start: \(queue.count) video(s), "
                        + Format.bytes(queue.reduce(0) { $0 + $1.fileSize })) {
                        model.start(importModel.settings)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(queue.isEmpty || model.isScanning)
                }
            }
        }
        .padding()
        .background(.bar)
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
