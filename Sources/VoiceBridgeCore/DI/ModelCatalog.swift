import Foundation

/// A model the app can download for the user.
///
/// The old workflow was "open a terminal and run a script"; the downloader
/// (`ModelDownloader`) already knows how to stream a file with progress, a
/// SHA-256 check and a crash-safe write. This catalog is the *list* of what
/// can be downloaded, so the Settings page can offer a one-click install.
public struct DownloadableModel: Identifiable, Sendable, Equatable {

    public enum Kind: String, Sendable {
        case stt  // a whisper.cpp ggml model
        case sttQwen  // a Qwen3-ASR GGUF, served by llama-server
        case tts  // a Piper voice
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

    public init(
        id: String,
        displayName: String,
        kind: Kind,
        fileName: String,
        relativeDirectory: String,
        remoteURL: URL,
        byteSize: Int64 = 0,
        sha256: String? = nil,
        companions: [Companion] = []
    ) {
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
    ///
    /// Standardized because the Qwen3-ASR entries live one level *up* from the
    /// tts root (`../stt/qwen3`); without this the path would carry `..` and
    /// never compare equal to the directory the server reads from.
    public func destination(in root: ModelPaths) -> URL {
        root.root.appendingPathComponent(relativeDirectory, isDirectory: true)
            .appendingPathComponent(fileName)
            .standardizedFileURL
    }
}

/// The catalog of models the app can install on demand.
public enum ModelCatalog {

    private static let whisperBase = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
    private static let piperBase = "https://huggingface.co/rhasspy/piper-voices/resolve/main"
    /// BELLE-2's Chinese fine-tune, published as a whisper.cpp ggml.
    private static let belleZhBase =
        "https://huggingface.co/BELLE-2/Belle-whisper-large-v3-turbo-zh-ggml/resolve/main"
    /// Qwen3-ASR GGUFs, converted and published by the llama.cpp project.
    private static let qwenBase = "https://huggingface.co/ggml-org"

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
    ///
    /// `byteSize` and `sha256` are the *real* values for the files served today;
    /// `scripts/verify-catalog.sh` re-checks both against the server in CI, so a
    /// moved or re-uploaded file fails the build instead of a user's install.
    /// Every entry must carry a checksum — `ModelDownloadCatalogTests` enforces
    /// it, because a nil checksum silently disables the integrity check.
    public static let stt: [DownloadableModel] = [
        DownloadableModel(
            id: "large-v3-turbo",
            displayName: "Large-v3-turbo · best speed/accuracy (RECOMMENDED)",
            kind: .stt,
            fileName: "ggml-large-v3-turbo.bin",
            relativeDirectory: "whisper",
            remoteURL: url("\(whisperBase)/ggml-large-v3-turbo.bin"),
            byteSize: 1_624_555_275,
            sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"),
        DownloadableModel(
            id: "belle-large-v3-turbo-zh",
            displayName: "Chinese · Belle Large-v3-turbo (中文优化)",
            kind: .stt,
            // The repo serves the file as `ggml-model.bin`; it is saved under
            // the whisper naming the backend expects (`ggml-<id>.bin`).
            fileName: "ggml-belle-large-v3-turbo-zh.bin",
            relativeDirectory: "whisper",
            remoteURL: url("\(belleZhBase)/ggml-model.bin"),
            byteSize: 1_624_555_275,
            sha256: "2a3bba5bfdb4d4da3d9949a83b405711727ca1941d4d5810895e077eb3cb4d99"),
        DownloadableModel(
            id: "large-v3",
            displayName: "Large-v3 · maximum accuracy, slower",
            kind: .stt,
            fileName: "ggml-large-v3.bin",
            relativeDirectory: "whisper",
            remoteURL: url("\(whisperBase)/ggml-large-v3.bin"),
            byteSize: 3_095_033_483,
            sha256: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2"),
        DownloadableModel(
            id: "medium",
            displayName: "Medium · balanced accuracy",
            kind: .stt,
            fileName: "ggml-medium.bin",
            relativeDirectory: "whisper",
            remoteURL: url("\(whisperBase)/ggml-medium.bin"),
            byteSize: 1_533_763_059,
            sha256: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208"),
        DownloadableModel(
            id: "small",
            displayName: "Small · fast dictation",
            kind: .stt,
            fileName: "ggml-small.bin",
            relativeDirectory: "whisper",
            remoteURL: url("\(whisperBase)/ggml-small.bin"),
            byteSize: 487_601_967,
            sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"),
        DownloadableModel(
            id: "base",
            displayName: "Base · ultra-fast, low accuracy",
            kind: .stt,
            fileName: "ggml-base.bin",
            relativeDirectory: "whisper",
            remoteURL: url("\(whisperBase)/ggml-base.bin"),
            byteSize: 147_951_465,
            sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"),
        DownloadableModel(
            id: "tiny",
            displayName: "Tiny · fastest, low accuracy",
            kind: .stt,
            fileName: "ggml-tiny.bin",
            relativeDirectory: "whisper",
            remoteURL: url("\(whisperBase)/ggml-tiny.bin"),
            byteSize: 77_691_713,
            sha256: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21"),
    ]

    /// Piper text-to-speech voices.
    ///
    /// Each voice is a pair: the `.onnx` model and its `.onnx.json`
    /// configuration (Piper reads the config from next to the model).
    public static let tts: [DownloadableModel] = [
        DownloadableModel(
            id: "zh_CN-huayan-medium",
            displayName: "Chinese (Mandarin) · Huayan · medium (中文)",
            kind: .tts,
            fileName: "zh_CN-huayan-medium.onnx",
            relativeDirectory: "piper/voice",
            remoteURL: url("\(piperBase)/zh/zh_CN/huayan/medium/zh_CN-huayan-medium.onnx"),
            byteSize: 63_201_294,
            sha256: "9929917bf8cabb26fd528ea44d3a6699c11e87317a14765312420be230be0f3d",
            companions: [
                DownloadableModel.Companion(
                    fileName: "zh_CN-huayan-medium.onnx.json",
                    remoteURL: url(
                        "\(piperBase)/zh/zh_CN/huayan/medium/zh_CN-huayan-medium.onnx.json"))
            ]),
        DownloadableModel(
            id: "en_US-lessac-medium",
            displayName: "English (US) · Lessac · medium",
            kind: .tts,
            fileName: "en_US-lessac-medium.onnx",
            relativeDirectory: "piper/voice",
            remoteURL: url("\(piperBase)/en/en_US/lessac/medium/en_US-lessac-medium.onnx"),
            byteSize: 63_201_294,
            sha256: "5efe09e69902187827af646e1a6e9d269dee769f9877d17b16b1b46eeaaf019f",
            companions: [
                DownloadableModel.Companion(
                    fileName: "en_US-lessac-medium.onnx.json",
                    remoteURL: url(
                        "\(piperBase)/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json"))
            ]),
        DownloadableModel(
            id: "en_US-amy-medium",
            displayName: "English (US) · Amy · medium",
            kind: .tts,
            fileName: "en_US-amy-medium.onnx",
            relativeDirectory: "piper/voice",
            remoteURL: url("\(piperBase)/en/en_US/amy/medium/en_US-amy-medium.onnx"),
            byteSize: 63_221_984,
            sha256: "cf9ccdec59f05adee47173f6fb4d89e8b0c5f30c178748d2572fe4efd1d2724c",
            companions: [
                DownloadableModel.Companion(
                    fileName: "en_US-amy-medium.onnx.json",
                    remoteURL: url("\(piperBase)/en/en_US/amy/medium/en_US-amy-medium.onnx.json"))
            ]),
    ]

    /// Qwen3-ASR speech-to-text models.
    ///
    /// Each tier is **two files**: the weights and the audio projector
    /// (`mmproj-…`) that turns audio into tokens for them. Downloading only
    /// the first produces a server that starts and then fails every request,
    /// which is why the projector is a `companion` and not an optional extra.
    ///
    /// The URLs are written out in full rather than composed from
    /// `QwenAsrTier`, because `scripts/verify-catalog.sh` reads this table
    /// textually — an interpolated URL would be skipped by the verifier, which
    /// is exactly the kind of silent rot that script exists to catch.
    /// `QwenAsrTests` keeps these file names in step with the tier enum.
    public static let qwen: [DownloadableModel] = [
        DownloadableModel(
            id: "qwen3-asr-0.6b",
            displayName: "Qwen3-ASR 0.6B · fastest, 30 languages + 22 dialects",
            kind: .sttQwen,
            fileName: QwenAsrTier.fast.modelFileName,
            relativeDirectory: "../stt/qwen3",
            remoteURL: url(
                "\(qwenBase)/Qwen3-ASR-0.6B-GGUF/resolve/main/Qwen3-ASR-0.6B-Q8_0.gguf"),
            byteSize: 804_749_248,
            sha256: "bca259818b50ca7c4c05e9bdb35a5dc04fa039653a6d6f3f0f331f96f6aa1971",
            companions: [
                DownloadableModel.Companion(
                    fileName: QwenAsrTier.fast.mmprojFileName,
                    remoteURL: url(
                        "\(qwenBase)/Qwen3-ASR-0.6B-GGUF/resolve/main/mmproj-Qwen3-ASR-0.6B-Q8_0.gguf"
                    ))
            ]),
        DownloadableModel(
            id: "qwen3-asr-1.7b",
            displayName: "Qwen3-ASR 1.7B · most accurate",
            kind: .sttQwen,
            fileName: QwenAsrTier.accurate.modelFileName,
            relativeDirectory: "../stt/qwen3",
            remoteURL: url(
                "\(qwenBase)/Qwen3-ASR-1.7B-GGUF/resolve/main/Qwen3-ASR-1.7B-Q8_0.gguf"),
            byteSize: 2_165_034_944,
            sha256: "58e22d0532d4eacaf034cfac17a6fed159f37c41390c710186783be439d1fc57",
            companions: [
                DownloadableModel.Companion(
                    fileName: QwenAsrTier.accurate.mmprojFileName,
                    remoteURL: url(
                        "\(qwenBase)/Qwen3-ASR-1.7B-GGUF/resolve/main/mmproj-Qwen3-ASR-1.7B-Q8_0.gguf"
                    ))
            ]),
    ]

    /// Everything, STT first.
    public static var all: [DownloadableModel] { stt + qwen + tts }

    /// The catalog entry for a whisper model.
    public static func model(for sttModel: SttModel) -> DownloadableModel? {
        stt.first { $0.id == sttModel.rawValue }
    }
}
