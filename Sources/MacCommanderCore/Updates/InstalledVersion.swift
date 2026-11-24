import Foundation

/// Picks the app's own version string out of its Info dictionary. Pure, so Core stays bundle-free.
public enum InstalledVersion {
    /// `NXReleaseVersion` (the full tag version, pre-release suffix included, stamped by the release workflow)
    /// when it is a non-empty string, else `CFBundleShortVersionString` (three integers only), else `nil`.
    /// The first matters: a `0.2.0-beta.1` build whose short version reads `0.2.0` would compare as up to
    /// date against the final `v0.2.0`.
    public static func string(from info: [String: Any]?) -> String? {
        if let release = info?["NXReleaseVersion"] as? String, !release.isEmpty { return release }
        return info?["CFBundleShortVersionString"] as? String
    }
}
