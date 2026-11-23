import Foundation
import Testing

@testable import MacCommanderCore

struct CloudStorageProviderTests {
    @Test func folderNamesBecomeProviderAndAccount() {
        #expect(CloudStorageProvider.displayName(forFolder: "OneDrive-Agentur3BGmbH") == "OneDrive – Agentur3BGmbH")
        #expect(CloudStorageProvider.displayName(forFolder: "OneDrive-Personal") == "OneDrive – Personal")
        #expect(CloudStorageProvider.displayName(forFolder: "GoogleDrive-me@gmail.com") == "Google Drive – me@gmail.com")
        #expect(CloudStorageProvider.displayName(forFolder: "ProtonDrive-daniel@dginx.de-folder") == "Proton Drive – daniel@dginx.de")
        #expect(CloudStorageProvider.displayName(forFolder: "Nextcloud-cloud.example.com-Daniel") == "Nextcloud – cloud.example.com-Daniel")
        #expect(CloudStorageProvider.displayName(forFolder: "Dropbox") == "Dropbox")
        #expect(CloudStorageProvider.displayName(forFolder: "SomeApp-Work") == "SomeApp – Work")
        #expect(CloudStorageProvider.displayName(forFolder: "OneDrive-") == "OneDrive")
    }

    /// One row per account folder: hidden entries and plain files are skipped, the rest sorted by name.
    @Test func listsAccountFoldersOnly() async throws {
        let tmp = try TemporaryDirectory()
        _ = try tmp.folder("OneDrive-Work")
        _ = try tmp.folder("Dropbox")
        _ = try tmp.folder("OneDrive-Personal")
        _ = try tmp.file(".DS_Store")
        _ = try tmp.file("notes.txt")

        let locations = await CloudStorageProvider.locations(in: tmp.url)

        #expect(locations.map(\.name) == ["Dropbox", "OneDrive – Personal", "OneDrive – Work"])
        #expect(locations.first?.url.lastPathComponent == "Dropbox")
    }

    @Test func missingFolderListsNothing() async {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(await CloudStorageProvider.locations(in: missing).isEmpty)
    }
}
