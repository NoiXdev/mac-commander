// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacCommander",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "MacCommander", targets: ["MacCommander"])],
    targets: [
        .target(name: "MacCommanderCore"),
        .executableTarget(name: "MacCommander", dependencies: ["MacCommanderCore"]),
        .testTarget(name: "MacCommanderCoreTests", dependencies: ["MacCommanderCore"]),
    ]
)
