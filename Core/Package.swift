// swift-tools-version: 6.0
// Package manifest for CaffeinateCore — see docs/plan/06-engineering.md §1/§2.
//
// Dependency discipline (review decision R4, plan 06 §2):
// - HookWire depends on Foundation only (wire protocol shared by app and bridge).
// - caff-bridge depends ONLY on HookWire (structurally enforced here; check-bridge.sh
//   double-checks the linked-library whitelist).
// - CaffeinateCore depends on HookWire (AgentKind is defined on the wire layer and is
//   referenced by HoldSourceID / AppStateSnapshot).
// - AgentDetection depends on CaffeinateCore + HookWire.

import PackageDescription

let package = Package(
    name: "CaffeinateCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CaffeinateCore", targets: ["CaffeinateCore"]),
        .library(name: "AgentDetection", targets: ["AgentDetection"]),
        .library(name: "CaffeinateComposition", targets: ["CaffeinateComposition"]),
        .library(name: "HookWire", targets: ["HookWire"]),
        .executable(name: "caff-bridge", targets: ["caff-bridge"]),
        .executable(name: "caff-smoke", targets: ["caff-smoke"]),
    ],
    targets: [
        .target(
            name: "HookWire"
        ),
        .target(
            name: "CaffeinateCore",
            dependencies: ["HookWire"]
        ),
        .target(
            name: "AgentDetection",
            dependencies: ["CaffeinateCore", "HookWire"]
        ),
        // The composition root (plan 01 PR-6) must see both the engine
        // (CaffeinateCore) and the detection layer (AgentDetection), and
        // AgentDetection already depends on CaffeinateCore — so the root lives
        // in its own target on top of both rather than inside CaffeinateCore.
        .target(
            name: "CaffeinateComposition",
            dependencies: ["CaffeinateCore", "AgentDetection", "HookWire"]
        ),
        .executableTarget(
            name: "caff-bridge",
            dependencies: ["HookWire"]
        ),
        .executableTarget(
            name: "caff-smoke",
            dependencies: ["CaffeinateCore"]
        ),
        .testTarget(
            name: "CaffeinateCoreTests",
            dependencies: ["CaffeinateCore", "AgentDetection", "CaffeinateComposition", "HookWire"],
            exclude: ["Fixtures"] // loaded via #filePath, not Bundle.module
        ),
    ],
    swiftLanguageModes: [.v5]
)
