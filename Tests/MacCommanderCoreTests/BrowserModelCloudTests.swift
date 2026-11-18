import Foundation
import Testing

@testable import MacCommanderCore

@MainActor
private final class CallLog {
    var calls: [String] = []
}

@MainActor
@Suite struct BrowserModelCloudTests {
    private func makeStore() -> ViewSettingsStore {
        ViewSettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    private func item(_ status: CloudStatus?) -> FileItem {
        var item = FileItem(
            url: URL(fileURLWithPath: "/virtual/doc.txt"), name: "doc.txt",
            isDirectory: false, isPackage: false, isHidden: false,
            size: 1, dateModified: nil, dateCreated: nil, dateAdded: nil, kind: "")
        item.cloudStatus = status
        return item
    }

    private func model(_ log: CallLog) throws -> BrowserModel {
        let temp = try TemporaryDirectory()
        return BrowserModel(
            start: temp.url, settings: makeStore(),
            opener: { log.calls.append("open \($0.lastPathComponent)") },
            downloader: { log.calls.append("download \($0.lastPathComponent)") })
    }

    @Test func openNotDownloadedTriggersDownload() async throws {
        let log = CallLog()
        await (try model(log)).open(item(.notDownloaded))
        #expect(log.calls == ["download doc.txt", "open doc.txt"])
    }

    @Test func openDownloadedSkipsDownload() async throws {
        let log = CallLog()
        let model = try model(log)
        await model.open(item(.current))
        await model.open(item(nil))
        #expect(log.calls == ["open doc.txt", "open doc.txt"])
    }
}
