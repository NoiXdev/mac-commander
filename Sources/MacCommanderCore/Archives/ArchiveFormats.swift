import Foundation

/// The file extensions MacCommander treats as archives, matched against the end of the file name
/// case-insensitively, so compound extensions such as "tar.gz" work.
public enum ArchiveFormats {
    /// Pure archives: these open as folders on double-click / ⌘↓.
    static let pureExtensions = [
        "zip", "tar", "tgz", "tar.gz", "tbz", "tbz2", "tar.bz2", "txz", "tar.xz", "7z", "rar",
    ]

    /// Container formats that are archives underneath, offered only through "Browse Contents".
    static let containerExtensions = [
        "docx", "xlsx", "pptx", "odt", "ods", "odp", "pages", "numbers", "key", "epub",
        "jar", "ipa", "apk", "xpi", "pkg", "xar", "iso", "cpio",
    ]

    /// True for pure archives (`a.zip`, `a.TAR.GZ`); false for containers like `.docx`.
    public static func isArchive(_ url: URL) -> Bool {
        matches(url, pureExtensions)
    }

    /// True for pure archives and container formats whose contents can be browsed.
    public static func isBrowsable(_ url: URL) -> Bool {
        matches(url, pureExtensions) || matches(url, containerExtensions)
    }

    /// The file name without its archive extension, matched like `isBrowsable` (longest extension wins):
    /// `assets.tar.gz` → `assets`, `a.ZIP` → `a`. Other names lose their last path extension.
    public static func baseName(of url: URL) -> String {
        let name = url.lastPathComponent
        let lowered = name.lowercased()
        let matching = (pureExtensions + containerExtensions)
            .filter { lowered.count > $0.count + 1 && lowered.hasSuffix("." + $0) }
            .max { $0.count < $1.count }
        if let matching, let range = name.range(of: "." + matching, options: [.caseInsensitive, .backwards, .anchored]) {
            return String(name[..<range.lowerBound])
        }
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }

    private static func matches(_ url: URL, _ extensions: [String]) -> Bool {
        let name = url.lastPathComponent.lowercased()
        // A bare "zip" (no stem) is not an archive name.
        return extensions.contains { name.count > $0.count + 1 && name.hasSuffix("." + $0) }
    }
}
