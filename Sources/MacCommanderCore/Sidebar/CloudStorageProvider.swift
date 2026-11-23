import Foundation

/// A cloud account's folder, as the provider's app (OneDrive, Google Drive, Dropbox, Nextcloud, …) keeps it
/// under `~/Library/CloudStorage`: one folder per account.
public struct CloudLocation: Identifiable, Hashable, Sendable {
    public let url: URL
    public var id: URL { url }
    /// "OneDrive – Agentur3BGmbH".
    public let name: String
}

public enum CloudStorageProvider {
    /// Where File Provider apps put their accounts' folders.
    public static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
    }

    /// The account folders in `folder` (hidden entries and files skipped), sorted by name. Off the main
    /// actor: a provider's folder may be slow to answer.
    public static func locations(in folder: URL = folder) async -> [CloudLocation] {
        await PathQueries.run {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            return urls
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
                .map { CloudLocation(url: $0, name: displayName(forFolder: $0.lastPathComponent)) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    /// Provider names as their apps spell them, by the folder name's first part.
    private static let providerNames = [
        "OneDrive": "OneDrive", "GoogleDrive": "Google Drive", "ProtonDrive": "Proton Drive",
        "Dropbox": "Dropbox", "Box": "Box", "Nextcloud": "Nextcloud", "ownCloud": "ownCloud",
    ]

    /// "<Provider>-<account>" as "Provider – account"; a folder without an account part is the provider alone.
    /// Proton Drive's "-folder" suffix is dropped.
    public static func displayName(forFolder folderName: String) -> String {
        guard let dash = folderName.firstIndex(of: "-") else {
            return providerNames[folderName] ?? folderName
        }
        let key = String(folderName[..<dash])
        let provider = providerNames[key] ?? key
        var account = String(folderName[folderName.index(after: dash)...])
        if key == "ProtonDrive", account.hasSuffix("-folder") { account.removeLast("-folder".count) }
        return account.isEmpty ? provider : "\(provider) – \(account)"
    }
}
