import Foundation

/// Whether the app has Full Disk Access, and where to grant it.
public enum FullDiskAccess {
    /// The Full Disk Access pane of System Settings.
    public static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// True when the probe (a folder macOS protects) can be listed. A probe that doesn't exist counts as granted,
    /// so the app never nags when it can't tell. Blocking: call it through `PathQueries.run`.
    public static func isGranted(
        probe: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Safari")
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: probe.path) else { return true }
        return (try? FileManager.default.contentsOfDirectory(atPath: probe.path)) != nil
    }
}
