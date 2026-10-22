import Foundation

/// A model the app can download for the user.
///
/// The old workflow was "open a terminal and run a script"; the downloader
/// (`ModelDownloader`) already knows how to stream a file with progress, a
/// SHA-256 check and a crash-safe write. This catalog is the *list* of what
/// can be downloaded, so the Settings page can offer a one-click install.
public struct DownloadableModel: Identifiable, Sendable, Equatable {

    public enum Kind: String, Sendable {
        case stt   // a whisper.cpp ggml model
        case tts   // a Piper voice
    }

    /// A file that must be fetched next to the model (e.g. Piper's
    /// `.onnx.json` configuration).
    public struct Companion: Sendable, Equatable {
        public let fileName: String
        public let remoteURL: URL

        public init(fileName: String, remoteURL: URL) {
            self.fileName = fileName
            self.remoteURL = remoteURL
            }
    }

    public let id: String
    public let displayName: String
    public let kind: Kind
    /// The name the file has on disk.
    public let fileName: String
    /// Where it lands under the model root ("whisper", "piper/voice", …).
    public let relativeDirectory: String
    public let remoteURL: URL
    /// Size in bytes when known (0 = unknown).
    public let byteSize: Int64
    /// SHA-256 of the file when known (nil = not verified).
    public let sha256: String?
    /// Extra files fetched alongside the model.
    public let companions: [Companion]

    public init(id: String,
                displayName: String,
                kind: Kind,
                fileName: String,
                relativeDirectory: String,
                remoteURL: URL,
                byteSize: Int64 = 0,
                sha256: String? = nil,
                companions: [Companion] = []) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.fileName = fileName
        self.relativeDirectory = relativeDirectory
        self.remoteURL = remoteURL
        self.byteSize = byteSize
        self.sha256 = sha256
        self.companions = companions
        }

    /// The destination inside a model root.
    public func destination(in root: ModelPaths) -> URL {
        root.root.appendingPathComponent(relativeDirectory, isDirectory: true)
            .appendingPathComponent(fileName)
    }
}

/// The catalog of models the app can install on demand.
public enum ModelCatalog {

    private static let whisperBase = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
    private static let piperBase = "https://huggingface.co/rhasspy/piper-voices/resolve/main"

       /// A URL built from a literal. A malformed literal is a programming
       /// error (not a runtime condition), so it traps instead of silently
       /// producing an unusable URL.
    private static func url(_ string: String) -> URL {
        guard let parsed = URL(string: string) else {
            preconditionFailure("VoiceBridge: malformed URL in the model catalog: \(string)")
            }
        return parsed
        }

    /// whisper.cpp speech-to-text models.
    public static let stt: [DownloadableModel] = [
        DownloadableModel(
            id: "large-v3-turbo",
            displayName: "Large-v3-turbo · best speed/accuracy (RECOMMENDED)",
            kind: .stt,
            fileName: "ggml-large-v3-turbo.bin",
            relativeDirectory: "whisper",
            remoteURL: url("\(whisperBase)/ggml-large-v3-turbo.bin"),
            byteSize: 1_752_944_432),
        DownloadableModel(
            id: "large-v3",
            displayName: "Large-v3 · maximum accuracy, slower",
            kind: .stt,
            fileName: "ggml-large-v3.bin",
            relativeDirectory: "whisper",
            remoteURL: url("\(whisperBase)/ggml-large-v3.bin"),
            byteSize: 3_087_659_584),
        DownloadableModel(
            id: "medium",
            displayName: "Medium · balanced accuracy",
            kind: .stt,
            fileName: "ggml-medium.bin",
            relativeDirectory: "whisper",
            remoteURL: url("\(whisperBase)/ggml-medium.bin"),
            byteSize: 1_516_533_520),
        DownloadableModel(
            id: "small",
            displayName: "Small · fast dictation",
            kind: .stt,
            fileName: "ggml-small.bin",
            relativeDirectory: "whisper",
            remoteURL: url("\(whisperBase)/ggml-small.bin"),
            byteSize: 485_557_560),
        DownloadableModel(
            id: "base",
            displayName: "Base · ultra-fast, low accuracy",
            kind: .stt,
            fileName: "ggml-base.bin",
            relativeDirectory: "whisper",
            remoteURL: url("\(whisperBase)/ggml-base.bin"),
            byteSize: 75_520_216),
        DownloadableModel(
            id: "tiny",
            displayName: "Tiny · fastest, low accuracy",
            kind: .stt,
            fileName: "ggml-tiny.bin",
            relativeDirectory: "whisper",
            remoteURL: url("\(whisperBase)/ggml-tiny.bin"),
            byteSize: 75_243_368),
    ]

    /// Piper text-to-speech voices.
    ///
    /// Each voice is a pair: the `.onnx` model and its `.onnx.json`
    /// configuration (Piper reads the config from next to the model).
    public static let tts: [DownloadableModel] = [
        DownloadableModel(
            id: "en_US-lessac-medium",
            displayName: "English (US) · Lessac · medium",
            kind: .tts,
            fileName: "en_US-lessac-medium.onnx",
            relativeDirectory: "piper/voice",
            remoteURL: url("\(piperBase)/en/en_US/lessac/medium/en_US-lessac-medium.onnx"),
            byteSize: 63_214_376,
            companions: [
                DownloadableModel.Companion(
                    fileName: "en_US-lessac-medium.onnx.json",
                    remoteURL: url("\(piperBase)/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json"))
            ]),
        DownloadableModel(
            id: "en_US-amy-medium",
            displayName: "English (US) · Amy · medium",
            kind: .tts,
            fileName: "en_US-amy-medium.onnx",
            relativeDirectory: "piper/voice",
            remoteURL: url("\(piperBase)/en/en_US/amy/medium/en_US-amy-medium.onnx"),
            byteSize: 63_213_112,
            companions: [
                DownloadableModel.Companion(
                    fileName: "en_US-amy-medium.onnx.json",
                    remoteURL: url("\(piperBase)/en/en_US/amy/medium/en_US-amy-medium.onnx.json"))
            ]),
        DownloadableModel(
            id: "zh_CN-huayan-medium",
            displayName: "Chinese (Mandarin) · Huayan · medium",
            kind: .tts,
            fileName: "zh_CN-huayan-medium.onnx",
            relativeDirectory: "piper/voice",
            remoteURL: url("\(piperBase)/zh/zh_CN/huayan/medium/zh_CN-huayan-medium.onnx"),
            byteSize: 63_212_888,
            companions: [
                DownloadableModel.Companion(
                    fileName: "zh_CN-huayan-medium.onnx.json",
                    remoteURL: url("\(piperBase)/zh/zh_CN/huayan/medium/zh_CN-huayan-medium.onnx.json"))
            ]),
    ]

    /// Everything, STT first.
    public static var all: [DownloadableModel] { stt + tts }

    /// The catalog entry for a whisper model.
    public static func model(for sttModel: SttModel) -> DownloadableModel? {
        stt.first { $0.id == sttModel.rawValue }
    }
}
