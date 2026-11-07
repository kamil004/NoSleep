// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NoSleep",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "NoSleep",
            path: "Sources/NoSleep"
        )
    ]
)