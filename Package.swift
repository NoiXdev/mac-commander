// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacCommander",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "MacCommander", targets: ["MacCommander"])],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", .upToNextMinor(from: "0.9.0")),
    ],
    targets: [
        .target(
            name: "MacCommanderCore",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")]
        ),
        .executableTarget(name: "MacCommander", dependencies: ["MacCommanderCore"]),
        .testTarget(name: "MacCommanderCoreTests", dependencies: ["MacCommanderCore"]),
    ]
)
