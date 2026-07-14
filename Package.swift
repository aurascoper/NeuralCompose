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
        .library(name: "BCIVoice",      targets: ["BCIVoice"]),
        .executable(name: "EmbeddingBench", targets: ["EmbeddingBench"]),
        .executable(name: "SemanticEval", targets: ["SemanticEval"]),
        .executable(name: "MLXProbe", targets: ["MLXProbe"]),
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
                // Sentence-embedding models (BERT family) for the Stage 3.4
                // RQ1 MLXSentenceEmbedder — mlx_lm cannot load encoders.
                .product(name: "MLXEmbedders",  package: "mlx-swift-examples"),
                .product(name: "Transformers", package: "swift-transformers"),
            ],
            path: "Sources/BCILLM",
            swiftSettings: strictConcurrency + [
                .define("BCI_HAS_MLX")
            ]
        ),

        // ── Push-to-talk dictation + TTS (system frameworks only) ─────────
        .target(
            name: "BCIVoice",
            dependencies: ["BCICore"],
            path: "Sources/BCIVoice",
            swiftSettings: strictConcurrency,
            linkerSettings: [.linkedFramework("Speech")]
        ),

        // ── Application ──────────────────────────────────────────────────
        .executableTarget(
            name: "NeuralComposeApp",
            dependencies: ["BCICore", "BCIEEG", "BCIBridge", "BCIClassifier", "BCILLM", "BCIVoice"],
            path: "Sources/NeuralComposeApp",
            // Info.plist lives in Resources/ for reference / Xcode builds but
            // is intentionally NOT declared as a SwiftPM resource: SwiftPM
            // forbids Info.plist as a top-level resource. `swift run` produces
            // a runnable binary without one.
            exclude: ["Resources/Info.plist"],
            swiftSettings: strictConcurrency
        ),

        // ── Embedding benchmark harness (Stage 3.1) ───────────────────────
        // Sibling executable, not a test target and not part of the app.
        // Depends only on BCICore so it can measure any `SentenceEmbedder`
        // conformer — including a future CoreMLSentenceEmbedder or
        // MLXSentenceEmbedder — without this target ever importing CoreML
        // or MLX itself. See docs/architecture/embedding_contract.md §6.
        .executableTarget(
            name: "EmbeddingBench",
            // BCIClassifier is needed to construct CoreMLSentenceEmbedder
            // (Stage 3.2) directly by its concrete type; BCILLM likewise for
            // MLXSentenceEmbedder (Stage 3.4 RQ1) — BenchmarkRunner itself
            // stays generic over `any SentenceEmbedder` and knows nothing
            // about Core ML or MLX. Single executable → still one MLX
            // runtime in the linked binary.
            dependencies: ["BCICore", "BCIClassifier", "BCILLM"],
            path: "Sources/EmbeddingBench",
            swiftSettings: strictConcurrency
        ),

        // ── Semantic evaluation (Stage 3.3) ───────────────────────────────
        // Sibling executable, generic over `any SentenceEmbedder` (a
        // `--model` flag picks the concrete conformer — argument parsing,
        // not a backend registry). Emits raw embeddings and cosine
        // relationships only; projection and clustering metrics are
        // derived downstream in Scripts/generate-semantic-eval-artifacts.py.
        .executableTarget(
            name: "SemanticEval",
            dependencies: ["BCICore", "BCIClassifier"],
            path: "Sources/SemanticEval",
            swiftSettings: strictConcurrency
        ),

        // ── MLX load probe (temporary diagnostic) ─────────────────────────
        // Isolated `MLXNextWordPredictor.init()` + `generate()` call with
        // none of `PredictorFactory`'s subprocess/semaphore/App-lifecycle
        // machinery around it. See Sources/MLXProbe/main.swift's doc
        // comment. Delete this target once the probe-subprocess stall is
        // diagnosed.
        .executableTarget(
            name: "MLXProbe",
            dependencies: ["BCILLM"],
            path: "Sources/MLXProbe",
            swiftSettings: strictConcurrency
        ),

        // ── Tests ────────────────────────────────────────────────────────
        .testTarget(
            name: "BCICoreTests",
            // BCIClassifier is pulled in for SemanticBGEReplayRegressionTests,
            // which exercises the same text -> SentenceEmbedder -> Embedding ->
            // RandomProjectionProjector pipeline as the stub's replay test, but
            // against CoreMLSentenceEmbedder (BCIClassifier). Same rationale as
            // BCIEEGTests pulling in BCIClassifier below: a dedicated
            // cross-module test target felt like overkill for one suite.
            dependencies: ["BCICore", "BCIClassifier"],
            path: "Tests/BCICoreTests"
        ),
        .testTarget(
            name: "BCIEEGTests",
            // BCIClassifier is pulled in for GoldenRecordingRegressionTests,
            // which exercises the full playback -> windowing -> features ->
            // classifier pipeline against a real recording. A dedicated
            // cross-module test target felt like overkill for one suite.
            dependencies: ["BCIEEG", "BCICore", "BCIClassifier"],
            path: "Tests/BCIEEGTests",
            // Fixtures/reference_pipeline.json is read directly by file path
            // (relative to #filePath) rather than through Bundle.module, so
            // it doesn't need SwiftPM resource bundling — just excluded so
            // the build doesn't warn about an unhandled file.
            exclude: ["Fixtures/reference_pipeline.json"]
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
        .testTarget(
            name: "BCIVoiceTests",
            dependencies: ["BCIVoice", "BCICore"],
            path: "Tests/BCIVoiceTests"
        ),
        .testTarget(
            name: "NeuralComposeAppTests",
            dependencies: ["NeuralComposeApp", "BCICore", "BCIEEG", "BCIClassifier", "BCILLM", "BCIVoice"],
            path: "Tests/NeuralComposeAppTests"
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
