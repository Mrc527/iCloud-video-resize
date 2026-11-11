import SwiftUI

@main
struct SDVideoImportApp: App {
    @StateObject private var importModel = ImportModel()
    @StateObject private var libraryModel = LibraryModel()

    var body: some Scene {
        WindowGroup {
            TabView {
                // New videos: made smaller before they go into Photos.
                ContentView()
                    .tabItem { Label("SD card", systemImage: "sdcard") }
                // Videos already in Photos: replaced by a smaller version.
                LibraryScreen()
                    .tabItem { Label("Photos library", systemImage: "photo.on.rectangle") }
            }
            .environmentObject(importModel)
            .environmentObject(libraryModel)
        }
    }
}
