import Foundation
import Testing

@testable import MacCommanderCore

@Suite struct FileSortOrderTests {
    private func item(
        _ name: String, directory: Bool = false, size: Int64? = nil, path: String? = nil,
        tags: [String] = []
    ) -> FileItem {
        var item = FileItem(
            url: URL(fileURLWithPath: "/virtual/\(path ?? name)"), name: name,
            isDirectory: directory, isPackage: false, isHidden: false,
            size: directory ? nil : size, dateModified: nil, dateCreated: nil, dateAdded: nil,
            kind: "")
        item.tags = tags.map { FileTag(name: $0, color: .none) }
        return item
    }

    private func names(_ order: FileSortOrder, _ items: [FileItem]) -> [String] {
        order.sorted(items).map(\.name)
    }

    @Test func sortsByTags() {
        let items = [item("x", tags: ["B"]), item("y", tags: ["A"]), item("z")]
        let order = FileSortOrder(column: .tags, ascending: true, foldersOnTop: false)
        #expect(names(order, items) == ["y", "x", "z"])
    }

    @Test func sortsByLocationThenName() {
        let items = [item("a", path: "dir10/a"), item("b", path: "dir2/b"), item("a", path: "dir2/a")]
        let order = FileSortOrder(column: .location, ascending: true, foldersOnTop: false)
        #expect(order.sorted(items).map(\.url.path) == ["/virtual/dir2/a", "/virtual/dir2/b", "/virtual/dir10/a"])
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

    @Test func sorts50kItemsQuickly() {
        let items = (0..<50_000).map { item("file\(($0 * 7919) % 50_000)") }
        let (result, elapsed) = threadCPUTime { FileSortOrder.default.sorted(items) }
        #expect(result.count == 50_000)
        #expect(result.first?.name == "file0")
        #expect(elapsed < .seconds(1))
    }
}
