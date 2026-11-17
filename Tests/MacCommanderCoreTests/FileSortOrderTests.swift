import Foundation
import Testing

@testable import MacCommanderCore

@Suite struct FileSortOrderTests {
    private func item(
        _ name: String, directory: Bool = false, size: Int64? = nil, path: String? = nil
    ) -> FileItem {
        FileItem(
            url: URL(fileURLWithPath: "/virtual/\(path ?? name)"), name: name,
            isDirectory: directory, isPackage: false, isHidden: false,
            size: directory ? nil : size, dateModified: nil, dateCreated: nil, dateAdded: nil,
            kind: "")
    }

    private func names(_ order: FileSortOrder, _ items: [FileItem]) -> [String] {
        order.sorted(items).map(\.name)
    }

    @Test func sortsNaturally() {
        let result = names(.default, ["file10", "file2", "File1"].map { item($0) })
        #expect(result == ["File1", "file2", "file10"])
    }

    @Test func sortsUmlautsWithBaseLetter() {
        let result = names(.default, ["Zebra", "Ärger", "Apfel"].map { item($0) })
        #expect(result == ["Apfel", "Ärger", "Zebra"])
    }

    @Test func nfdAndNfcCompareEqualAndTieBreakStable() {
        let nfd = item("Mu\u{0308}ller", path: "b")
        let nfc = item("Müller", path: "a")
        let other = item("Mutter", path: "c")
        let first = FileSortOrder.default.sorted([nfd, other, nfc])
        let second = FileSortOrder.default.sorted([nfc, nfd, other])
        #expect(first == second)
        #expect(first.map(\.url.path) == ["/virtual/a", "/virtual/b", "/virtual/c"])
    }

    @Test func descendingReverses() {
        var order = FileSortOrder.default
        order.ascending = false
        let result = names(order, ["a", "c", "b"].map { item($0) })
        #expect(result == ["c", "b", "a"])
    }

    @Test func sizeSortPutsFoldersAsZero() {
        let order = FileSortOrder(
            column: .size, ascending: true, foldersOnTop: false)
        let result = names(
            order,
            [item("big", size: 100), item("dir", directory: true), item("small", size: 5)])
        #expect(result == ["dir", "small", "big"])
    }

    @Test func foldersOnTopGroupsFolders() {
        let order = FileSortOrder(column: .name, ascending: true, foldersOnTop: true)
        let result = names(
            order,
            [item("a"), item("z", directory: true), item("b"), item("m", directory: true)])
        #expect(result == ["m", "z", "a", "b"])
    }
}
