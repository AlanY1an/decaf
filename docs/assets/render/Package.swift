// swift-tools-version: 6.0
// Offscreen render harness for Decaf's real SwiftUI views.
//
// Sources/DecafRender/App/*.swift are COPIES of the repo's App/*.swift,
// refreshed by build.sh on every run. DecafApp.swift is excluded (its @main
// would collide with main.swift). Nothing here is shipped.

import PackageDescription

let package = Package(
    name: "DecafRender",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../../Core")
    ],
    targets: [
        .executableTarget(
            name: "DecafRender",
            dependencies: [
                .product(name: "DecafCore", package: "Core"),
                .product(name: "AgentDetection", package: "Core"),
                .product(name: "DecafComposition", package: "Core"),
                .product(name: "HookWire", package: "Core"),
            ],
            linkerSettings: [
                // So Wordmark's Bundle.main lookup finds a version, exactly as
                // it does in the shipping app bundle (MARKETING_VERSION 0.1.0).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/HarnessInfo.plist",
                ])
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
