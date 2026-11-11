// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PowerTop",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PowerTop", targets: ["PowerTop"])],
    targets: [
        .executableTarget(
            name: "PowerTop",
            path: "PowerTop",
            exclude: ["Info.plist", "Assets.xcassets", "en.lproj", "zh-Hans.lproj"]
        ),
        .testTarget(name: "PowerTopTests", dependencies: ["PowerTop"])
    ]
)
