import Foundation
import Testing

@testable import MacCommanderCore

struct PathQueriesTests {
    @Test func pathInfoBasics() async throws {
        let dir = try TemporaryDirectory()
        let folder = try dir.folder("folder")
        let file = try dir.file("file.txt")
        let app = try dir.folder("Thing.app")

        let folderInfo = await PathQueries.info(folder)
        #expect(folderInfo.exists && folderInfo.isDirectory && !folderInfo.isRegularFile && !folderInfo.isPackage)

        let fileInfo = await PathQueries.info(file)
        #expect(fileInfo.exists && fileInfo.isRegularFile && !fileInfo.isDirectory)

        let missing = await PathQueries.info(dir.url.appendingPathComponent("missing"))
        #expect(missing.exists == false)

        let appInfo = await PathQueries.info(app)
        #expect(appInfo.isDirectory && appInfo.isPackage)

        #expect(await PathQueries.info(URL(fileURLWithPath: "/")).isLocalVolume == true)
    }

    @Test func symlinkToFolderIsAFolder() async throws {
        let dir = try TemporaryDirectory()
        let target = try dir.folder("target")
        let link = dir.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(await PathQueries.info(link).isDirectory)
        #expect(await PathQueries.resolvingSymlink(link).lastPathComponent == "target")
        #expect(await PathQueries.resolvingSymlink(target) == target)
    }

    @Test func brokenSymlinkIsAnEntryButDoesNotExist() async throws {
        let dir = try TemporaryDirectory()
        let link = dir.url.appendingPathComponent("broken")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: dir.url.appendingPathComponent("nowhere"))

        #expect(await PathQueries.entryExists(link))
        #expect(await PathQueries.info(link).exists == false)
    }
}
