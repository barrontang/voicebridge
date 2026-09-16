import Foundation

/// The dependency-injection seam for the core (the "meta-fix").
///
/// Findings 1, 2, 3, 4, 5, 11, and the two "missing" findings all trace back to
/// one structural fact: **the core read globals**. Model paths were statics,
/// binary discovery was copy-pasted, logging was `print`, and there was no way to
/// inject a fake environment in a test.
///
/// `VoiceBridgeEnvironment` bundles the collaborators a core type needs — model
/// paths, a binary locator, a cache dir, and the logger factory — into a single
/// `Sendable, Equatable, Codable` value that is *constructed once* at the top of
/// the call graph and *threaded down*. With this in place:
///    * Finding 1 & 2 become type errors, not bugs: `scanSttModels` / `makeEngine`
///      read `env.paths`, which always reflects the user's chosen root.
///    * Finding 3 has an obvious home — `AppPaths`.
///    * Finding 4 has an obvious home — `env.binaryLocator`.
///    * Finding 5 has an obvious home — `VBLog`.
///    * Finding 11 becomes trivial — a test injects a fake environment.
///
/// It is a value type so it is cheap to copy and `Sendable`, which the backends
/// (which may hop off the main actor) require. (`BinaryLocator` carries closures
/// so the container is not itself `Equatable`/`Cododable`; tests compare the two
/// fields they care about directly.)
public struct VoiceBridgeEnvironment: Sendable {

       /// On-disk model layout rooted at the user's chosen root.
    public var paths: ModelPaths

       /// The single, shared binary-discovery implementation.
    public var binaryLocator: BinaryLocator

    public init(paths: ModelPaths,
                  binaryLocator: BinaryLocator = BinaryLocator()) {
        self.paths = paths
        self.binaryLocator = binaryLocator
      }

       /// The conventional production environment: read the default root from the
       /// host and resolve binaries against the real `$PATH`. `nonisolated` so any
       /// backend can synthesize one off the main actor.
    public static func production(
         _ env: [String: String] = ProcessInfo.processInfo.environment) -> VoiceBridgeEnvironment {
        VoiceBridgeEnvironment(
            paths: ModelPaths.fromEnvironment(env),
            binaryLocator: BinaryLocator(environment: env))
        }

       /// Scratch output dir for this environment's generated audio.
    public var cacheDir: URL { paths.cacheDir }
}
