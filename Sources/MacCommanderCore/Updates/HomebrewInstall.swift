import Foundation

/// Detects an install managed by the Homebrew cask, so the update prompt can
/// point at `brew upgrade` instead of a download.
public enum HomebrewInstall {
    static let caskroomPaths = [
        "/opt/homebrew/Caskroom/maccommander",
        "/usr/local/Caskroom/maccommander",
    ]

    /// True when the cask's Caskroom folder exists (Apple silicon or Intel prefix).
    public static func isCask(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        caskroomPaths.contains(where: fileExists)
    }
}
