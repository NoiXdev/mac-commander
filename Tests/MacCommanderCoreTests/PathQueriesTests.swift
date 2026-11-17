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

    /// Hung lookups wait on GCD threads, not the cooperative pool: other async work keeps running.
    @Test func blockedLookupsDoNotStarveConcurrentTasks() async throws {
        let prefix = "/MacCommanderTests-blocked-\(UUID().uuidString)"
        PathQueries.setTestDelay(1, forPathsUnder: prefix)
        defer { PathQueries.setTestDelay(nil, forPathsUnder: prefix) }

        // Same priority throughout: the cooperative pool keeps separate threads per priority.
        let lookups = Task(priority: .userInitiated) {
            await withTaskGroup(of: PathInfo.self) { group in
                for i in 0..<40 { group.addTask { await PathQueries.info(URL(fileURLWithPath: "\(prefix)/\(i)")) } }
                for await _ in group {}
            }
        }
        try await Task.sleep(for: .milliseconds(100))

        let start = ContinuousClock.now
        let answer = await Task(priority: .userInitiated) { await Self.concurrentWork() }.value
        #expect(answer == 42)
        #expect(ContinuousClock.now - start < .milliseconds(500))
        await lookups.value
    }

    @Test func concurrentLookupsOfOnePathShareOneStat() async throws {
        let prefix = "/MacCommanderTests-shared-\(UUID().uuidString)"
        PathQueries.setTestDelay(0.5, forPathsUnder: prefix)
        defer { PathQueries.setTestDelay(nil, forPathsUnder: prefix) }
        let url = URL(fileURLWithPath: "\(prefix)/same")

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { _ = await PathQueries.info(url) } }
        }
        // All ten asked while the first lookup was still sleeping: one lookup served them all.
        #expect(PathQueries.testLookupCount(forPathsUnder: prefix) == 1)
    }

    @concurrent
    private static func concurrentWork() async -> Int { 42 }
}
