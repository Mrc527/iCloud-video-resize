// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "iCloudVideoResize",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // Used by the iPad app (iPad/SDVideoImport.xcodeproj).
        .library(name: "VideoResizeCore", targets: ["VideoResizeCore"]),
    ],
    targets: [
        // All the logic: Photos access, encoding, verification, state.
        .target(name: "VideoResizeCore"),
        // The macOS SwiftUI app.
        .executableTarget(name: "VideoResizeApp", dependencies: ["VideoResizeCore"]),
        .testTarget(name: "VideoResizeCoreTests", dependencies: ["VideoResizeCore"]),
    ]
)
