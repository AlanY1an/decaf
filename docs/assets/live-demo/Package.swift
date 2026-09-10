// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "DecafLiveDemo", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../../Core")],
    targets: [.executableTarget(name: "DecafLiveDemo", dependencies: [
        .product(name: "DecafCore", package: "Core"),
        .product(name: "AgentDetection", package: "Core"),
        .product(name: "DecafComposition", package: "Core"),
        .product(name: "HookWire", package: "Core")
    ])], swiftLanguageModes: [.v5])
