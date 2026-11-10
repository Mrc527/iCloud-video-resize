import SwiftUI

@main
struct VideoResizeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("iCloud Video Resize", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}
