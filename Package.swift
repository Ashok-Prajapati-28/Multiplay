// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MultiPlay",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(
            name: "MultiPlay",
            path: "Sources/MultiPlay"
        )
    ]
)
