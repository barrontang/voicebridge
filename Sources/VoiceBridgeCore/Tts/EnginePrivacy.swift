import Foundation

/// The one answer to "will this synthesis leave the Mac?".
///
/// Two functions used to answer it differently: `TTSMode.isOnline` said Fish
/// Audio is *always* online, while `TTSConfigManager.selectedEngineIsRemote`
/// said it is online only when the server is not on loopback. The GUI gated
/// consent on one, the CLI warned on the other (and only for Edge), and the
/// alert copy named Edge no matter what was selected.
///
/// Every surface now routes through here, so a new engine gets the right
/// consent behaviour from one switch instead of three.
public enum EnginePrivacy {

    /// True when synthesizing with `mode` transmits the text to another
    /// machine.
    ///
    /// * Edge TTS always does.
    /// * A served engine (Fish Audio) does only when its configured server is
    ///   not on loopback — the default local MLX server keeps the text here.
    /// * Piper, Kokoro and the built-in voice never do.
    public static func requiresNetwork(
        mode: TTSMode,
        modelRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        switch mode {
        case .edgeTTS:
            return true
        case .fishAudio:
            // Not configured → the manager falls back to the built-in voice, so
            // nothing is transmitted and there is nothing to ask about.
            guard
                let backend = FishAudioBackend.fromEnvironment(
                    environment, modelRoot: modelRoot)
            else { return false }
            return backend.requiresNetwork
        case .system, .piper, .kokoro:
            return false
        }
    }

    /// The name to use in consent copy ("send this to **Foo**?").
    public static func remoteServiceName(for mode: TTSMode) -> String {
        switch mode {
        case .edgeTTS: return "Microsoft's Edge speech service"
        case .fishAudio: return "the Fish Audio server"
        case .system, .piper, .kokoro: return "a remote service"
        }
    }

    /// A one-line consent message, or `nil` when nothing leaves the machine.
    public static func consentMessage(
        for mode: TTSMode,
        modelRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard requiresNetwork(mode: mode, modelRoot: modelRoot, environment: environment) else {
            return nil
        }
        return "“\(mode.displayName)” is online: your text is sent to "
            + remoteServiceName(for: mode) + " and does not stay on this Mac. "
            + "Pick a local engine (Piper, Kokoro, Built-in) to stay offline."
    }
}
