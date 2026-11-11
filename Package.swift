// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FontHelper",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "FontHelper", path: "Sources/FontHelper")
    ]
)
