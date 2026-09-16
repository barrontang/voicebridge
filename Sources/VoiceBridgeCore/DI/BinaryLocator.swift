import Foundation

/// A single, testable implementation of "find an executable on the host"
/// (Finding 4).
///
/// The old code duplicated this logic in at least three places — the shell's
/// `Shell.pathLookup`, the CLI's `whisperAvailable`/`piperAvailable`/
/// `edgeAvailable`, and `WhisperCliBackend.resolveBinary` — with *subtly
/// different* search orders (env var, Homebrew prefixes, `$PATH`, …). Each copy
/// drifted over time, which is precisely how a "binary is installed but the
/// engine reports missing" bug hides for months.
///
/// Everything now funnels through here. It is injectable: we hand it the `PATH`
/// value and the known package-manager prefixes as data, so a test can feed a
/// fake filesystem + environment and assert the exact resolution order without
/// touching the real host.
public struct BinaryLocator: Sendable {

          /// Data the locator searches. Defaults mirror a real macOS host; tests
         /// inject their own.
     public struct SearchPaths: Sendable {
       /// `PATH` to split on `:`.
        public var path: String
        /// Extra prefixes searched *before* `$PATH`, e.g. Homebrew cellars.
        public var extraPrefixes: [String]

        public init(path: String,
                     extraPrefixes: [String] = BinaryLocator.homebrewPrefixes) {
            self.path = path
            self.extraPrefixes = extraPrefixes
            }
      }

        /// Homebrew locations, Apple-Silicon first, then Intel.
    public static let homebrewPrefixes: [String] = [
         "/opt/homebrew/opt/whisper-cpp/bin",
         "/usr/local/opt/whisper-cpp/bin",
         "/opt/homebrew/bin",
         "/usr/local/bin",
         ]

     private let searchPaths: SearchPaths
     // The `IsExecutable` seam is an `@unchecked Sendable` box: it hides either a
     // real `FileManager` check or an injected closure, both of which are
     // effectively immutable for the lifetime of the locator.
       private let check: Check

        /// Production locator: real filesystem + this process's environment.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.searchPaths = SearchPaths(
            path: environment["PATH"] ?? "",
             extraPrefixes: BinaryLocator.homebrewPrefixes)
        self.check = .system
         }

        /// Test seam: inject the search paths and an `isExecutable` closure.
    public init(searchPaths: SearchPaths, isExecutable: @escaping (String) -> Bool) {
        self.searchPaths = searchPaths
        self.check = .closure(isExecutable)
        }

      // A `Check` is either the real filesystem or an injected predicate.
     private enum Check {
        case system
        case closure(@Sendable (String) -> Bool)

     func isExecutable(atPath path: String) -> Bool {
            switch self {
            case .system:
                return FileManager.default.isExecutableFile(atPath: path)
             case .closure(let f):
                return f(path)
              }
        }
     }

         /// Whether `name` resolves to a real executable using the documented
          /// order:
          ///          1. an absolute path supplied by the caller (already-resolved),
          ///          2. `extraPrefixes` in order,
          ///          3. `$PATH` in order.
          ///
          /// Returns the absolute path that resolved, or nil when absent.
    public func locate(_ name: String) -> String? {
           // 1. A full, directly-executable path short-circuits everything.
        if isAbsolute(name), check.isExecutable(atPath: name) { return name }

        let base = (name as NSString).lastPathComponent

         // 2. Known package-manager prefixes.
        for prefix in searchPaths.extraPrefixes {
            let candidate = (prefix as NSString).appendingPathComponent(base)
            if check.isExecutable(atPath: candidate) { return candidate }
            }

          // 3. $PATH, the way a shell resolves a bare command.
        for dir in searchPaths.path.components(separatedBy: ":") where !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent(base)
            if check.isExecutable(atPath: candidate) { return candidate }
             }
        return nil
        }

         /// Convenience: true when `name` is reachable by any of the three steps.
      public func isAvailable(_ name: String) -> Bool { locate(name) != nil }

       /// Returns an *absolute* path suitable for `Process(executableURL:)`, or the
        /// original input when it cannot be resolved (preserving the old "fall back to
         /// the bare name so the child's own error surfaces" behaviour).
    public func resolveOrPassthrough(_ input: String) -> String {
        locate(input) ?? input
       }

      /// Best-effort absolute path — prefers an env-var override, then the
        /// documented search, then the bare name.
    public func resolve(preferred envVar: String?,
                        _ name: String,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let envVar, let env = environment[envVar], check.isExecutable(atPath: env) {
            return env
            }
        return locate(name) ?? name
        }

        private func isAbsolute(_ s: String) -> Bool {
            s.hasPrefix("/") || (s as NSString).isAbsolutePath
        }
}
