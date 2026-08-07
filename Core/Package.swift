// swift-tools-version: 6.0
// Package manifest for DecafCore — see docs/plan/06-engineering.md §1/§2.
//
// Dependency discipline (review decision R4, plan 06 §2):
// - HookWire depends on Foundation only (wire protocol shared by app and bridge).
// - decaf-bridge depends ONLY on HookWire (structurally enforced here; check-bridge.sh
//   double-checks the linked-library whitelist).
// - DecafCore depends on HookWire (AgentKind is defined on the wire layer and is
//   referenced by HoldSourceID / AppStateSnapshot).
// - AgentDetection depends on DecafCore + HookWire.

import PackageDescription

let package = Package(
    name: "DecafCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DecafCore", targets: ["DecafCore"]),
        .library(name: "AgentDetection", targets: ["AgentDetection"]),
        .library(name: "DecafComposition", targets: ["DecafComposition"]),
        .library(name: "HookWire", targets: ["HookWire"]),
        .library(name: "UsageMetering", targets: ["UsageMetering"]),
        .executable(name: "decaf-bridge", targets: ["decaf-bridge"]),
        .executable(name: "decaf-statusline", targets: ["decaf-statusline"]),
        .executable(name: "decaf-smoke", targets: ["decaf-smoke"]),
    ],
    targets: [
        .target(
            name: "HookWire"
        ),
        .target(
            name: "DecafCore",
            dependencies: ["HookWire"]
        ),
        // Strict-JSON helpers shared by transcript readers (AgentDetection's
        // wait-signal parser and UsageMetering's usage parser). `package`
        // access: visible inside this package, invisible to the app target.
        .target(
            name: "TranscriptSupport"
        ),
        // Usage metering (plan 09): transcript token ledger. Depends ONLY on
        // TranscriptSupport — no DecafCore/AgentDetection coupling.
        .target(
            name: "UsageMetering",
            dependencies: ["TranscriptSupport"]
        ),
        .target(
            name: "AgentDetection",
            dependencies: ["DecafCore", "HookWire", "TranscriptSupport"]
        ),
        // The composition root (plan 01 PR-6) must see both the engine
        // (DecafCore) and the detection layer (AgentDetection), and
        // AgentDetection already depends on DecafCore — so the root lives
        // in its own target on top of both rather than inside DecafCore.
        .target(
            name: "DecafComposition",
            dependencies: ["DecafCore", "AgentDetection", "HookWire"]
        ),
        .executableTarget(
            name: "decaf-bridge",
            dependencies: ["HookWire"]
        ),
        // Statusline-to-socket bridge (plan 09 M2): same R4 discipline as
        // decaf-bridge — HookWire only.
        .executableTarget(
            name: "decaf-statusline",
            dependencies: ["HookWire"]
        ),
        .executableTarget(
            name: "decaf-smoke",
            dependencies: ["DecafCore"]
        ),
        .testTarget(
            name: "DecafCoreTests",
            dependencies: ["DecafCore", "AgentDetection", "DecafComposition", "HookWire", "UsageMetering", "TranscriptSupport"],
            exclude: ["Fixtures"] // loaded via #filePath, not Bundle.module
        ),
    ],
    swiftLanguageModes: [.v5]
)
