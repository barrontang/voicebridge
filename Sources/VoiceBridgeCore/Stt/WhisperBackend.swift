import Foundation

/// The pluggable STT contract. Two implementations ship today
/// (`WhisperCliBackend`, future `InProcessWhisper`). Keeping this a protocol
/// is what lets the GUI swap engines without touching call sites.
public protocol WhisperBackend: Sendable {
     /// Transcribe an audio file to text.
    func transcribe(audio: URL, language: String?, model: SttModel,
                    useTimestamps: Bool) async throws -> Transcription
}

/// Options that travel with a transcription request.
public struct WhisperOptions: Sendable {
    public var language: String?      // nil = auto-detect
    public var useTimestamps: Bool
    public var beamSize: Int
    public var vadFilter: Bool        // drop non-speech segments

    public init(language: String? = nil,
                useTimestamps: Bool = false,
                beamSize: Int = 5,
                vadFilter: Bool = true) {
        self.language = language
        self.useTimestamps = useTimestamps
        self.beamSize = beamSize
        self.vadFilter = vadFilter
    }
}
