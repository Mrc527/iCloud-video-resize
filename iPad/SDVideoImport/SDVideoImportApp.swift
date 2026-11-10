import SwiftUI

@main
struct SDVideoImportApp: App {
    @StateObject private var model = ImportModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}
