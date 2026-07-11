import BCICore
import Foundation

/// Zero-dependency fallback — touches no AVFoundation API at all, so
/// resolving this never requires any system permission or hardware.
public final class StubSpeechSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    public let isLive = false
    public let voiceIdentifier = "stub-silent"

    public init() {}

    public func speak(_ text: String) async throws {
        BCILog.voice.notice("Stub TTS: would speak \(text.count, privacy: .public) characters")
    }

    public func stopSpeaking() async {}
}
