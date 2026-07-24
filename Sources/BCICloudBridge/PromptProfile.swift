import CryptoKit
import Foundation

/// A `PromptProfile` is a system prompt consumed by every
/// `GenerationRuntime` conformer. Prompt profiles are repository
/// resources (Markdown files under `Sources/BCICloudBridge/Prompts/`);
/// the runtime does not own them. The dialectical engine owns semantics;
/// the runtime owns transport. (ADR-009 invariant #1.)
///
/// Loading is once-per-process: the loader reads from the bundle on
/// first access, caches the bytes, and returns the cached value on
/// subsequent calls. Hashing is by sha256 of the loaded bytes —
/// `prompt_hash` in the generator fingerprint is the value the
/// telemetry records.
public enum PromptProfile: String, CaseIterable, Sendable {
    /// The passive mirror for the hypnagogic (N1) rung. Reserved for
    /// future sleep modes; not used by the current (waking) profiles.
    case hypnagogic

    /// The waking dialectical exchange. Used by Focused, Reflective,
    /// and Contemplative profiles.
    case wakingDialectical

    /// The non-voiced post-compete observer. Used by the Reflective
    /// profile's Witness only.
    case witness

    /// The Markdown filename (relative to `Sources/BCICloudBridge/Prompts/`)
    /// the loader reads.
    public var filename: String {
        switch self {
        case .hypnagogic:          return "hypnagogic.md"
        case .wakingDialectical:   return "waking-dialectical.md"
        case .witness:             return "witness.md"
        }
    }

    /// The bundle resource name. SwiftPM's `.process("Prompts")` flattens
    /// the directory into the bundle root, so the resource is just the
    /// basename (no `Prompts/` prefix). The Markdown files are declared
    /// as resources on the BCICloudBridge target via
    /// `resources: [.process("Prompts")]` in Package.swift.
    public var resourceName: String {
        (filename as NSString).deletingPathExtension
    }

    /// The system prompt text. Loaded once from the bundle; cached.
    /// Throws if the resource is missing (a build / packaging bug).
    public func load() throws -> String {
        try load(using: .standard)
    }

    /// Loading against an explicit locator. The injectable seam exists so the
    /// missing-bundle and missing-file paths are testable without disturbing
    /// the real app layout.
    ///
    /// This deliberately does NOT go through SwiftPM's generated
    /// `Bundle.module`. That accessor is a `static let` whose initializer
    /// calls `fatalError()` when the resource bundle is absent, so it traps
    /// inside the lazy global's `dispatch_once` — before any Swift error
    /// exists and out of reach of `try`/`catch`. A packaged .app missing the
    /// bundle died with SIGTRAP here instead of throwing `missingResource`.
    /// Absence must be a value, not an assertion.
    public func load(using locator: PromptResourceLocator) throws -> String {
        let key = self.cacheKey
        let cacheable = locator.isStandard
        if cacheable {
            Self.cacheLock.lock()
            if let cached = Self.cache[key] {
                Self.cacheLock.unlock()
                return cached
            }
            Self.cacheLock.unlock()
        }

        guard let url = locator.url(forResource: resourceName, withExtension: "md") else {
            throw PromptProfileError.missingResource(filename, searched: locator.searchedPaths)
        }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw PromptProfileError.invalidUTF8(filename)
        }
        // The Markdown files are stored with a leading newline (the
        // body begins on the line after the file's first character)
        // and a trailing newline (the file ends with a single blank
        // line). The original Swift `"""..."""` block returned the
        // body text without those wrapping newlines; we strip them
        // here so the loaded text is byte-identical to the pre-extraction
        // static let values.
        let trimmed = Self.trim(text)
        // An empty constraining prompt is the failure this whole path exists
        // to prevent: `claude -p --system-prompt ""` is an unconstrained model
        // on the one deliberate network-egress path. Treat it as a missing
        // resource rather than a usable value.
        guard !trimmed.isEmpty else {
            throw PromptProfileError.emptyResource(filename)
        }
        if cacheable {
            Self.cacheLock.lock()
            Self.cache[key] = trimmed
            Self.cacheLock.unlock()
        }
        return trimmed
    }

    /// The sha256 hex digest of the loaded prompt bytes. Stable across
    /// runs of the same build; the value the telemetry records as
    /// `prompt_hash`. Computed once; cached.
    public func hash() throws -> String {
        let key = self.cacheKey
        Self.hashCacheLock.lock()
        if let cached = Self.hashCache[key] {
            Self.hashCacheLock.unlock()
            return cached
        }
        Self.hashCacheLock.unlock()
        let hex = Self.sha256Hex(try load())
        Self.hashCacheLock.lock()
        Self.hashCache[key] = hex
        Self.hashCacheLock.unlock()
        return hex
    }

    /// sha256 of arbitrary prompt bytes.
    ///
    /// Runtimes hash the text they actually send rather than re-hashing a
    /// `PromptProfile`. On the system-prompt-override path those differ, and
    /// hashing the profile made `promptHash` attest to bytes that were never
    /// transmitted — defeating the fingerprint's stated purpose.
    public static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Private

    /// The cache key is the raw value (a String). Using the enum as a
    /// dictionary key directly is possible but String keys avoid any
    /// `Hashable on enum with associated values` confusion if the
    /// enum grows.
    private var cacheKey: String { rawValue }

    // The caches are protected by NSLock (cacheLock / hashCacheLock);
    // strict concurrency's MutableGlobalVariable diagnostic is suppressed
    // via nonisolated(unsafe) because the lock IS the synchronization
    // mechanism. Same pattern as the `CLIInvocation` class in
    // ClaudeCLIGenerator.swift.
    nonisolated(unsafe) private static var cache: [String: String] = [:]
    nonisolated(unsafe) private static var hashCache: [String: String] = [:]
    private static let cacheLock = NSLock()
    private static let hashCacheLock = NSLock()

    private static func trim(_ s: String) -> String {
        var t = s
        if t.hasPrefix("\n") { t.removeFirst() }
        if t.hasSuffix("\n") { t.removeLast() }
        return t
    }
}

public enum PromptProfileError: Error, CustomStringConvertible {
    case missingResource(String, searched: [String])
    case invalidUTF8(String)
    case emptyResource(String)

    public var description: String {
        switch self {
        case .missingResource(let f, let searched):
            return "PromptProfileError: resource '\(f)' not found in the "
                + "\(PromptResourceLocator.bundleName) bundle. This is a packaging bug — "
                + "the SwiftPM resource bundle was not copied into the app. Searched: "
                + searched.joined(separator: ", ")
        case .invalidUTF8(let f):
            return "PromptProfileError: resource '\(f)' is not valid UTF-8"
        case .emptyResource(let f):
            return "PromptProfileError: resource '\(f)' is empty; refusing to use an "
                + "unconstrained system prompt on the network egress path"
        }
    }
}

/// Locates prompt resources without ever evaluating SwiftPM's generated
/// `Bundle.module`.
///
/// `Bundle.module` is a `static let` whose generated initializer ends in
/// `fatalError()`. When the resource bundle is missing from a packaged .app,
/// merely *touching* it traps the process (SIGTRAP) during `dispatch_once`,
/// so no amount of `try`/`catch` at the call site can recover. This type
/// searches an explicit candidate list and returns `nil` instead.
///
/// Candidate roots cover the three layouts the resources actually appear in:
/// a packaged `.app` (`Contents/Resources`, plus the `Contents`-level
/// symlink), a plain SwiftPM build (the bundle sits beside the executable in
/// `.build/<config>/`), and the XCTest bundle layout.
public struct PromptResourceLocator: Sendable {
    /// SwiftPM names resource bundles `<PackageName>_<TargetName>`.
    /// Pinned by `PromptProfileTests.testStandardLocatorFindsBundle`, which
    /// fails if a package/target rename ever invalidates this string.
    public static let bundleName = "NeuralCompose_BCICloudBridge"

    private let roots: [URL]
    let isStandard: Bool

    public init(roots: [URL]) {
        self.roots = roots
        self.isStandard = false
    }

    private init(standardRoots: [URL]) {
        self.roots = standardRoots
        self.isStandard = true
    }

    /// The locator used by the app and CLI.
    public static var standard: PromptResourceLocator {
        .init(standardRoots: defaultRoots())
    }

    /// Paths consulted, for diagnostics in `missingResource`.
    public var searchedPaths: [String] { roots.map(\.path) }

    /// The resource URL, or `nil` if absent. Never traps.
    public func url(forResource name: String, withExtension ext: String) -> URL? {
        let file = "\(name).\(ext)"
        let fm = FileManager.default
        for root in roots {
            let bundleRoot = root.appendingPathComponent("\(Self.bundleName).bundle")
            let candidates = [
                // SwiftPM on macOS emits a FLAT resource bundle: the .md files
                // sit directly inside the .bundle directory.
                bundleRoot.appendingPathComponent(file),
                // A bundle restructured into the conventional macOS layout.
                bundleRoot.appendingPathComponent("Contents/Resources").appendingPathComponent(file),
                // Resources copied loose into the search root.
                root.appendingPathComponent(file),
            ]
            for candidate in candidates where fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func defaultRoots() -> [URL] {
        var out: [URL] = []
        func add(_ url: URL?) {
            guard let url, !out.contains(url) else { return }
            out.append(url)
        }
        let main = Bundle.main
        add(main.resourceURL)                                  // packaged .app: Contents/Resources
        add(main.bundleURL)                                    // Contents-level symlink
        add(main.executableURL?.deletingLastPathComponent())   // .build/<config>, Contents/MacOS
        let anchor = Bundle(for: LocatorAnchor.self)
        add(anchor.resourceURL)                                // XCTest bundle
        add(anchor.bundleURL)
        add(anchor.bundleURL.deletingLastPathComponent())
        return out
    }
}

/// Anchor class so `Bundle(for:)` can resolve the bundle enclosing this
/// module under XCTest. Never instantiated.
private final class LocatorAnchor {}
