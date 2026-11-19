import Foundation
import Testing

@testable import MacCommanderCore

final class FakeGlobalDefaultsStore: GlobalDefaultsStore, @unchecked Sendable {
    var values: [String: String]

    init(_ values: [String: String] = [:]) { self.values = values }

    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String?, forKey key: String) { values[key] = value }
}

@Suite struct FileViewerSettingTests {
    private let bundleID = "dev.noix.MacCommander"

    @Test func enableWritesBundleID() {
        let store = FakeGlobalDefaultsStore()
        let setting = FileViewerSetting(bundleIdentifier: bundleID, store: store)
        setting.setEnabled(true)
        #expect(store.string(forKey: "NSFileViewer") == "dev.noix.MacCommander")
        #expect(setting.isEnabled)
    }

    @Test func disableRemovesOwnValue() {
        let store = FakeGlobalDefaultsStore()
        let setting = FileViewerSetting(bundleIdentifier: bundleID, store: store)
        setting.setEnabled(true)
        setting.setEnabled(false)
        #expect(store.string(forKey: "NSFileViewer") == nil)
        #expect(!setting.isEnabled)
    }

    @Test func disableLeavesOtherViewer() {
        let store = FakeGlobalDefaultsStore(["NSFileViewer": "com.cocoatech.PathFinder"])
        let setting = FileViewerSetting(bundleIdentifier: bundleID, store: store)
        #expect(!setting.isEnabled)
        setting.setEnabled(false)
        #expect(store.string(forKey: "NSFileViewer") == "com.cocoatech.PathFinder")
    }

    @Test func comparisonIgnoresCase() {
        let store = FakeGlobalDefaultsStore(["NSFileViewer": "DEV.NOIX.MacCommander"])
        let setting = FileViewerSetting(bundleIdentifier: bundleID, store: store)
        #expect(setting.isEnabled)
    }
}
