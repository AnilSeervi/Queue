// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Queue",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Queue",
            path: "Sources/Queue"
        )
    ]
)
