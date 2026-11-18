import Foundation
import Testing

@testable import MacCommanderCore

@MainActor
struct TagCatalogTests {
    private let red = FileTag(name: "Red", color: .red)
    private let orange = FileTag(name: "Orange", color: .orange)

    @Test func mergeOrdersStandardThenCustom() {
        let merged = TagCatalog.merge(standard: [red, orange], inUse: ["zeta", "red", "Alpha"], known: [])
        #expect(merged.map(\.name) == ["Red", "Orange", "Alpha", "zeta"])
        #expect(merged.map(\.color) == [.red, .orange, .none, .none])
    }

    @Test func mergeUsesKnownColors() {
        let merged = TagCatalog.merge(
            standard: [red, orange], inUse: ["alpha"], known: [FileTag(name: "Alpha", color: .blue)])
        #expect(merged.last?.name == "alpha")
        #expect(merged.last?.color == .blue)
    }

    @Test func noteUsedAddsCustom() {
        let catalog = TagCatalog()
        catalog.noteUsed(FileTag(name: "Project", color: .green))
        #expect(catalog.tags.contains(FileTag(name: "project", color: .none)))
        #expect(catalog.tags.first { $0.name == "Project" }?.color == .green)
    }
}
