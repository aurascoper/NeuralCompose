// swift-tools-version: 6.0
//
// NeuralCompose — Privacy-first macOS BCI communication prototype.
//
// Module layout (MLX isolation is load-bearing):
//
//   NeuralComposeApp  (executable, SwiftUI)
//        │
//        ├── BCICore         pure-Swift models, protocols, buffers, intent FSM
//        ├── BCIEEG          BrainFlow facade + synthetic + playback streams
//        ├── BCIClassifier   Core ML wrapper (ANE-preferred) + mock classifier
//        └── BCILLM          MLX-Swift adapter + stub predictor + tokenizer
//
// MLX-Swift and swift-transformers are linked ONLY into BCILLM.
// The app target talks to BCILLM through the `NextWordPredicting` protocol from
// BCICore, so there is exactly one MLX runtime copy in the linked binary.
//
// BrainFlow is intentionally NOT a SwiftPM dependency. It is an optional system
// library, surfaced through the BCIBridge C++/Obj-C++ shim and gated by the
// `BCI_BRAINFLOW_AVAILABLE` compile flag. Without it, BCIEEG transparently
// falls back to the synthetic stream so the app builds and runs out-of-the-box.

import PackageDescription

let package = Package(
    name: "NeuralCompose",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "NeuralCompose", targets: ["NeuralComposeApp"]),
        .library(name: "BCICore",       targets: ["BCICore"]),
        .library(name: "BCIEEG",        targets: ["BCIEEG"]),
        .library(name: "BCIClassifier", targets: ["BCIClassifier"]),
        .library(name: "BCILLM",        targets: ["BCILLM"]),
    ],
    dependencies: [
        // MLX runtime + small-model utilities. Pinned conservatively; bump as
        // upstream releases stabilize. BCILLM is the *only* target that
        // imports any of these products.
        .package(url: "https://github.com/ml-explore/mlx-swift",          from: "0.21.2"),
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", from: "2.21.0"),
        // Tokenizer + chat-template utilities. Used strictly offline.
        .package(url: "https://github.com/huggingface/swift-transformers", from: "0.1.20"),
    ],
    targets: [
        // ── C++/Obj-C++ bridge ────────────────────────────────────────────
        .target(
            name: "BCIBridge",
            path: "Sources/BCIBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                // Default to stub mode. Define BCI_BRAINFLOW_AVAILABLE at
                // build time (and provide -lBrainflow / header path) to wire
                // in a real BrainFlow installation.
                .define("BCI_BRIDGE_STUB"),
            ]
        ),

        // ── Core abstractions, no third-party deps ────────────────────────
        .target(
            name: "BCICore",
            path: "Sources/BCICore",
            swiftSettings: strictConcurrency
        ),

        // ── EEG streaming ────────────────────────────────────────────────
        .target(
            name: "BCIEEG",
            dependencies: ["BCICore", "BCIBridge"],
            path: "Sources/BCIEEG",
            swiftSettings: strictConcurrency
        ),

        // ── Core ML intent classifier ────────────────────────────────────
        .target(
            name: "BCIClassifier",
            dependencies: ["BCICore"],
            path: "Sources/BCIClassifier",
            swiftSettings: strictConcurrency
        ),

        // ── MLX LLM (isolated) ───────────────────────────────────────────
        .target(
            name: "BCILLM",
            dependencies: [
                "BCICore",
                .product(name: "MLX",           package: "mlx-swift"),
                .product(name: "MLXNN",         package: "mlx-swift"),
                .product(name: "MLXRandom",     package: "mlx-swift"),
                .product(name: "MLXLLM",        package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon",   package: "mlx-swift-examples"),
                .product(name: "Transformers", package: "swift-transformers"),
            ],
            path: "Sources/BCILLM",
            swiftSettings: strictConcurrency + [
                .define("BCI_HAS_MLX")
            ]
        ),

        // ── Application ──────────────────────────────────────────────────
        .executableTarget(
            name: "NeuralComposeApp",
            dependencies: ["BCICore", "BCIEEG", "BCIClassifier", "BCILLM"],
            path: "Sources/NeuralComposeApp",
            // Info.plist lives in Resources/ for reference / Xcode builds but
            // is intentionally NOT declared as a SwiftPM resource: SwiftPM
            // forbids Info.plist as a top-level resource. `swift run` produces
            // a runnable binary without one.
            exclude: ["Resources/Info.plist"],
            swiftSettings: strictConcurrency
        ),

        // ── Tests ────────────────────────────────────────────────────────
        .testTarget(
            name: "BCICoreTests",
            dependencies: ["BCICore"],
            path: "Tests/BCICoreTests"
        ),
        .testTarget(
            name: "BCIEEGTests",
            dependencies: ["BCIEEG", "BCICore"],
            path: "Tests/BCIEEGTests"
        ),
        .testTarget(
            name: "BCIClassifierTests",
            dependencies: ["BCIClassifier", "BCICore"],
            path: "Tests/BCIClassifierTests"
        ),
        .testTarget(
            name: "BCILLMTests",
            dependencies: ["BCILLM", "BCICore"],
            path: "Tests/BCILLMTests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)

// MARK: - Shared Swift settings

var strictConcurrency: [SwiftSetting] {
    [
        .enableExperimentalFeature("StrictConcurrency"),
        .enableUpcomingFeature("ExistentialAny"),
        // Not enabling InternalImportsByDefault — it forces every public
        // signature touching Foundation types (UUID, URL, Data) to either
        // re-export Foundation or wrap them. The friction isn't worth it
        // for an executable + four internal libraries that always link
        // together.
    ]
}
