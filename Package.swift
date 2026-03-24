// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyWhisper",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MyWhisper",
            path: "Sources/MyWhisper",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
