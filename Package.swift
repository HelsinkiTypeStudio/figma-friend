// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FontHelper",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CZlib", linkerSettings: [.linkedLibrary("z")]),
        .executableTarget(name: "FontHelper", dependencies: ["CZlib"], path: "Sources/FontHelper"),
    ]
)
