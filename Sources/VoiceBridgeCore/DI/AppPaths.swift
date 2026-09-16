import Foundation

/// Canonical, *persistent* locations for VoiceBridge user data (Finding 3).
///
/// The old `persistURL` computed:
///
///     FileManager.default.temporaryDirectory.deletingLastPathComponent()
///                             .appendingPathComponent("voicebridge/config.json")
///
/// which resolves to `DARWIN_USER_TEMP_DIR` — e.g.
/// `/var/folders/xx/…/T/voicebridge/config.json`. That directory is on the
/// per-user temp region the OS **reclaims at boot and under disk pressure**.
/// The user's chosen model root, selected voice, and STT model silently vanished
/// between runs — an active, user-visible data-loss bug.
///
/// `deletingLastPathComponent()` was also a meaningless "go up one level" attempt
/// that did nothing useful; it has been removed.
///
/// User configuration now lives in the standard, persistent
/// `~/Library/Application Support/VoiceBridge/` directory.
public enum AppPaths {

     /// The application-support base, created on demand.
    public static func supportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        let dir = base.appendingPathComponent("VoiceBridge", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
      }

        /// The canonical settings file.
    public static func configURL() throws -> URL {
        try supportDirectory().appendingPathComponent("config.json")
      }

        /// The **legacy** settings location (before this fix): the per-user temp
       /// region. Used only to seed a one-time migration.
    public static func legacyConfigURL() -> URL {
        FileManager.default.temporaryDirectory
          .appendingPathComponent("voicebridge", isDirectory: true)
          .appendingPathComponent("config.json")
       }

      /// One-time, non-destructive migration: if a legacy config exists and the
       /// new one does not yet, move it over. Idempotent and safe to call on every
       /// launch — it no-ops once the new file exists.
     @discardableResult
    public static func migrateLegacyConfigIfNeeded(
        legacy: URL = legacyConfigURL()) -> Bool {
        guard let dest = try? configURL() else { return false }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dest.path),
              fm.fileExists(atPath: legacy.path) else { return false }
        do {
            try fm.moveItem(at: legacy, to: dest)   // moves the file itself
             // Best-effort prune of the now-empty legacy `voicebridge/` dir.
            _ = try? fm.removeItem(at: legacy.deletingLastPathComponent())
            return true
          } catch {
            return false
          }
      }
}
