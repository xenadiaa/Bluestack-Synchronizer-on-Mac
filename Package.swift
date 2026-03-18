// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SynchronizerApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SynchronizerApp", targets: ["SynchronizerApp"])
    ],
    targets: [
        .executableTarget(
            name: "SynchronizerApp",
            path: "Sources"
        )
    ]
)
