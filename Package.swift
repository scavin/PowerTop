// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PowerTop",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PowerTop", targets: ["PowerTop"])],
    dependencies: [
        .package(
            url: "https://github.com/theMomax/BatteryView.git",
            revision: "a800142347e2fc5e344a547fb29b6d46c3dddcf1"
        )
    ],
    targets: [
        .executableTarget(
            name: "PowerTop",
            dependencies: [.product(name: "BatteryView", package: "BatteryView")],
            path: "PowerTop",
            exclude: ["Info.plist", "Assets.xcassets", "en.lproj", "zh-Hans.lproj"]
        ),
        .testTarget(name: "PowerTopTests", dependencies: ["PowerTop"])
    ]
)
