import FileProvider
import Foundation

/// A cloud account's folder, as the provider's app (OneDrive, Google Drive, Dropbox, Nextcloud, …) keeps it
/// under `~/Library/CloudStorage`: one folder per account.
public struct CloudLocation: Identifiable, Hashable, Sendable {
    public let url: URL
    public var id: URL { url }
    /// "OneDrive – Agentur3BGmbH".
    public let name: String
    /// "OneDrive".
    public let provider: String
    /// The provider's app, when known (to tell whether it runs).
    public let appBundleID: String?
    /// Whether the folder is a File Provider account macOS knows. A folder left behind by a removed account
    /// (or an app that no longer registers it) isn't.
    public let isConnected: Bool

    public init(url: URL, name: String, provider: String, appBundleID: String?, isConnected: Bool) {
        self.url = url
        self.name = name
        self.provider = provider
        self.appBundleID = appBundleID
        self.isConnected = isConnected
    }

    /// Active only while the account is known and its app runs: without the app nothing syncs. A provider
    /// whose app isn't known counts as running.
    public func status(isRunning: (String) -> Bool) -> CloudAccountStatus {
        guard isConnected else { return .disconnected }
        guard let appBundleID else { return .active }
        return isRunning(appBundleID) ? .active : .appNotRunning
    }
}

public enum CloudAccountStatus: Sendable, Equatable {
    case active, appNotRunning, disconnected
}

public enum CloudStorageProvider {
    /// Where File Provider apps put their accounts' folders.
    public static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
    }

    /// The account folders in `folder` (hidden entries and files skipped), sorted by name, each with whether
    /// it's a connected account (`isConnected`, by default `isAccountRoot`). Off the main actor: a provider's
    /// folder may be slow to answer.
    public static func locations(
        in folder: URL = folder, isConnected: @escaping @Sendable (URL) async -> Bool = isAccountRoot
    ) async -> [CloudLocation] {
        let urls = await PathQueries.run {
            ((try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        }
        var locations: [CloudLocation] = []
        for url in urls {
            let key = providerKey(forFolder: url.lastPathComponent)
            locations.append(CloudLocation(
                url: url, name: displayName(forFolder: url.lastPathComponent), provider: providerNames[key] ?? key,
                appBundleID: appBundleIDs[key], isConnected: await isConnected(url)))
        }
        return locations.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Whether macOS knows `url` as the root of a File Provider account. For a leftover folder it reports that
    /// the file doesn't exist (in any account).
    public static func isAccountRoot(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            NSFileProviderManager.getIdentifierForUserVisibleFile(at: url) { item, _, _ in
                continuation.resume(returning: item == .rootContainer)
            }
        }
    }

    /// Provider names as their apps spell them, by the folder name's first part.
    private static let providerNames = [
        "OneDrive": "OneDrive", "GoogleDrive": "Google Drive", "ProtonDrive": "Proton Drive",
        "Dropbox": "Dropbox", "Box": "Box", "Nextcloud": "Nextcloud", "ownCloud": "ownCloud",
    ]

    /// The providers' apps, by the folder name's first part.
    private static let appBundleIDs = [
        "OneDrive": "com.microsoft.OneDrive", "GoogleDrive": "com.google.drivefs",
        "ProtonDrive": "ch.protonmail.drive", "Dropbox": "com.getdropbox.dropbox", "Box": "com.box.desktop",
        "Nextcloud": "com.nextcloud.desktopclient", "ownCloud": "com.owncloud.desktopclient",
    ]

    private static func providerKey(forFolder folderName: String) -> String {
        folderName.firstIndex(of: "-").map { String(folderName[..<$0]) } ?? folderName
    }

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
