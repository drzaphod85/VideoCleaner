// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VideoCleaner",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "VideoCleanerCore",
            path: "Sources/VideoCleanerCore"
        ),
        .executableTarget(
            name: "VideoCleaner",
            dependencies: ["VideoCleanerCore"],
            path: "Sources/VideoCleaner"
        ),
        .testTarget(
            name: "VideoCleanerCoreTests",
            dependencies: ["VideoCleanerCore"],
            path: "Tests/VideoCleanerCoreTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
