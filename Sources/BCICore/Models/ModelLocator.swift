import Foundation

/// Where a model lives on disk.
///
/// Model paths like `Models/BGE-small-en-v1.5` used to be resolved against the
/// process's working directory only. That is the repo under `swift run`, but `/`
/// for an app opened from Finder or `open`, so the installed app looked in
/// `/Models/...`, found nothing, and fell back to stubs (every Aug 7 and Oct 13
/// health record says `embedderKind: stub`). Lookup order:
///
///   1. `$NEURALCOMPOSE_MODELS_DIR/<name>`
///   2. `Models/<name>` relative to the working directory, so `swift run` from
///      the repo keeps using the repo's copy
///   3. `~/Library/Application Support/NeuralCompose/Models/<name>`, where the
///      installed app finds them (filled by `Scripts/install-models.sh`)
///
/// The first that exists wins. When none exists, (2) is returned, so the
/// caller's "not found" log names the same path it always has. Per-model env
/// overrides (`NEURALCOMPOSE_MLX_MODEL` and friends) are checked by each
/// factory before this.
public enum ModelLocator {
    public static let environmentKey = "NEURALCOMPOSE_MODELS_DIR"

    /// `~/Library/Application Support/NeuralCompose/Models`.
    public static func applicationSupportModels() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("NeuralCompose", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// `name` is a model's file or folder name under a models directory, e.g.
    /// `"BGE-small-en-v1.5"` or `"IntentClassifier.mlmodelc"`.
    public static func url(
        for name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectoryModels: URL = URL(fileURLWithPath: "Models"),
        applicationSupport: URL? = applicationSupportModels()
    ) -> URL {
        let local = workingDirectoryModels.appendingPathComponent(name)
        let override = environment[environmentKey].flatMap { $0.isEmpty ? nil : $0 }
        let candidates = [
            override.map { URL(fileURLWithPath: $0).appendingPathComponent(name) },
            local,
            applicationSupport?.appendingPathComponent(name),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? local
    }
}
