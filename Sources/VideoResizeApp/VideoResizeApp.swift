import SwiftUI

@main
struct VideoResizeApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var card = CardModel()

    var body: some Scene {
        Window("iCloud Video Resize", id: "main") {
            TabView {
                // Videos already in Photos: replaced by a smaller version.
                ContentView()
                    .tabItem { Label("Photos library", systemImage: "photo.on.rectangle") }
                // New videos: made smaller before they go into Photos.
                CardView()
                    .tabItem { Label("SD card", systemImage: "sdcard") }
            }
            .environmentObject(model)
            .environmentObject(card)
        }
        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}
