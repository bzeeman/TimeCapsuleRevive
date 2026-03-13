// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TimeCapsuleApp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TimeCapsuleApp",
            path: "Sources/TimeCapsuleApp"
        ),
    ]
)
