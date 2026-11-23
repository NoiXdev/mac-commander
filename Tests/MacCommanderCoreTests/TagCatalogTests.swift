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

    /// A renamed or deleted tag stays hidden while Spotlight's index still reports it, and comes back once
    /// Spotlight has dropped it and finds it again.
    @Test func forgottenTagWaitsForSpotlight() {
        let catalog = TagCatalog()
        catalog.updateInUse(["Old", "Keep"])
        catalog.forget(FileTag(name: "old", color: .none))
        #expect(catalog.tags.map(\.name) == ["Keep"])

        catalog.updateInUse(["Old", "Keep"])
        #expect(catalog.tags.map(\.name) == ["Keep"])

        catalog.updateInUse(["Keep"])
        catalog.updateInUse(["Old", "Keep"])
        #expect(catalog.tags.map(\.name) == ["Keep", "Old"])
    }

    @Test func knownTagsAreReportedForSaving() {
        let catalog = TagCatalog()
        var saved: [[FileTag]] = []
        catalog.onKnownChange = { saved.append($0) }
        catalog.start(standard: [red], known: [FileTag(name: "Work", color: .blue)])
        #expect(catalog.tags.first { $0.name == "Work" }?.color == .blue)

        catalog.noteUsed(FileTag(name: "Home", color: .green))
        catalog.forget(FileTag(name: "work", color: .none))
        #expect(saved.map { $0.map(\.name) } == [["Work", "Home"], ["Home"]])
    }
}
