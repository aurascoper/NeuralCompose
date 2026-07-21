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
        let key = self.cacheKey
        Self.cacheLock.lock()
        if let cached = Self.cache[key] {
            Self.cacheLock.unlock()
            return cached
        }
        Self.cacheLock.unlock()

        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "md") else {
            throw PromptProfileError.missingResource(filename)
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
        Self.cacheLock.lock()
        Self.cache[key] = trimmed
        Self.cacheLock.unlock()
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
        let bytes = try load()
        let data = Data(bytes.utf8)
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        Self.hashCacheLock.lock()
        Self.hashCache[key] = hex
        Self.hashCacheLock.unlock()
        return hex
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
    case missingResource(String)
    case invalidUTF8(String)

    public var description: String {
        switch self {
        case .missingResource(let f): return "PromptProfileError: resource '\(f)' not found in BCICloudBridge bundle"
        case .invalidUTF8(let f):     return "PromptProfileError: resource '\(f)' is not valid UTF-8"
        }
    }
}
