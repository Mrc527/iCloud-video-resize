// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "iCloudVideoResize",
    platforms: [.macOS(.v14)],
    targets: [
        // All the logic: Photos access, encoding, verification, state.
        .target(name: "VideoResizeCore"),
        // The SwiftUI app.
        .executableTarget(name: "VideoResizeApp", dependencies: ["VideoResizeCore"]),
        .testTarget(name: "VideoResizeCoreTests", dependencies: ["VideoResizeCore"]),
    ]
)
