import Foundation
import Testing
@testable import MacCommanderCore

/// A fixture with `src/`, `dst/` and a fake `Trash/`; the stack never touches the real Trash.
@MainActor
private struct Fixture {
    let tmp: TemporaryDirectory
    let src: URL
    let dst: URL
    let trashFolder: URL
    let stack: FileUndoStack

    init(limit: Int = 50) throws {
        tmp = try TemporaryDirectory()
        src = try tmp.folder("src")
        dst = try tmp.folder("dst")
        trashFolder = try tmp.folder("Trash")
        stack = FileUndoStack(trash: fakeTrash(into: trashFolder), limit: limit)
    }

    var trash: @Sendable (URL) throws -> URL { fakeTrash(into: trashFolder) }

    func write(_ url: URL, _ contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func trashContents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: trashFolder.path).sorted()
    }
}

@MainActor
struct FileUndoStackTests {
    @Test func undoRename() async throws {
        let f = try Fixture()
        let a = f.src.appendingPathComponent("a.txt")
        let b = f.src.appendingPathComponent("b.txt")
        try f.write(b, "A")  // as if a.txt had been renamed to b.txt
        f.stack.push(FileUndoRecord(action: .rename(from: a, to: b), title: "Rename"))
        #expect(f.stack.undoTitle == "Rename")

        let restored = try await f.stack.undo()

        #expect(restored == [a])
        #expect(try f.read(a) == "A")
        #expect(!f.exists(b))
        #expect(f.stack.records.isEmpty)
        #expect(f.stack.undoTitle == nil)
    }

    @Test func undoCaseOnlyRename() async throws {
        let f = try Fixture()
        let lower = f.src.appendingPathComponent("a.txt")
        let upper = f.src.appendingPathComponent("A.txt")
        try f.write(upper, "A")
        f.stack.push(FileUndoRecord(action: .rename(from: lower, to: upper), title: "Rename"))

        _ = try await f.stack.undo()

        #expect(try FileManager.default.contentsOfDirectory(atPath: f.src.path) == ["a.txt"])
        #expect(try f.read(lower) == "A")
    }

    @Test func undoMoveAndCopy() async throws {
        let f = try Fixture()
        // Move src/a → dst/a, undone.
        let srcA = f.src.appendingPathComponent("a")
        let dstA = f.dst.appendingPathComponent("a")
        try f.write(dstA, "moved")
        f.stack.push(
            FileUndoRecord(
                action: .transferred(.move, [TransferredItem(source: srcA, destination: dstA)], replaced: []),
                title: "Move of “a”"))
        let restored = try await f.stack.undo()
        #expect(restored == [srcA])
        #expect(try f.read(srcA) == "moved")
        #expect(!f.exists(dstA))

        // Copy src/a → dst/a, undone: the copy goes to the Trash, the original stays.
        try f.write(dstA, "moved")
        f.stack.push(
            FileUndoRecord(
                action: .transferred(.copy, [TransferredItem(source: srcA, destination: dstA)], replaced: []),
                title: "Copy of “a”"))
        let restoredCopy = try await f.stack.undo()
        #expect(restoredCopy == [])
        #expect(!f.exists(dstA))
        #expect(try f.trashContents() == ["a"])
        #expect(try f.read(srcA) == "moved")
        #expect(f.stack.records.isEmpty)
    }

    @Test func undoSkipsNoOpMoves() async throws {
        let f = try Fixture()
        let a = try f.tmp.file("src/a", contents: "A")
        f.stack.push(
            FileUndoRecord(
                action: .transferred(.move, [TransferredItem(source: a, destination: a)], replaced: []),
                title: "Move"))
        _ = try await f.stack.undo()
        #expect(try f.read(a) == "A")
    }

    @Test func undoCreatedTrashesItems() async throws {
        let f = try Fixture()
        let folder = try f.tmp.folder("src/untitled folder")
        f.stack.push(FileUndoRecord(action: .created([folder]), title: "New Folder"))
        #expect(try await f.stack.undo() == [])
        #expect(!f.exists(folder))
        #expect(try f.trashContents() == ["untitled folder"])
    }

    @Test func undoTrashPutsBack() async throws {
        let f = try Fixture()
        let a = try f.tmp.file("src/a.txt", contents: "keep me")
        let result = await Trasher.trash([a], using: f.trash)
        #expect(!f.exists(a))
        f.stack.push(FileUndoRecord(action: .trashed(result.trashed), title: "Move to Trash"))

        let restored = try await f.stack.undo()

        #expect(restored == [a])
        #expect(try f.read(a) == "keep me")
        #expect(try f.trashContents() == [])
    }

    @Test func undoReplaceRestoresReplacedItem() async throws {
        let f = try Fixture()
        let srcA = try f.tmp.file("src/a", contents: "new")
        let dstA = f.dst.appendingPathComponent("a")
        let oldInTrash = try f.tmp.file("Trash/a", contents: "old")
        try f.write(dstA, "new")
        f.stack.push(
            FileUndoRecord(
                action: .transferred(
                    .copy, [TransferredItem(source: srcA, destination: dstA)],
                    replaced: [TrashedItem(original: dstA, trashed: oldInTrash)]),
                title: "Copy of “a”"))

        _ = try await f.stack.undo()

        #expect(try f.read(dstA) == "old")
        #expect(try f.read(srcA) == "new")
        // The new copy was trashed while the old item was still in the Trash, hence "a 2".
        #expect(try f.trashContents() == ["a 2"])
        #expect(try f.read(f.trashFolder.appendingPathComponent("a 2")) == "new")
    }

    @Test func undoRefusesWhenOriginalOccupied() async throws {
        let f = try Fixture()
        let srcA = f.src.appendingPathComponent("a.txt")
        let dstA = f.dst.appendingPathComponent("a.txt")
        try f.write(dstA, "moved")
        f.stack.push(
            FileUndoRecord(
                action: .transferred(.move, [TransferredItem(source: srcA, destination: dstA)], replaced: []),
                title: "Move of “a.txt”"))
        try f.write(srcA, "newcomer")

        await #expect(throws: UndoError.itemChanged(name: "a.txt")) { try await f.stack.undo() }

        #expect(try f.read(srcA) == "newcomer")
        #expect(try f.read(dstA) == "moved")
        #expect(f.stack.records.isEmpty)
    }

    @Test func undoRefusesWhenItemGone() async throws {
        let f = try Fixture()
        let srcA = f.src.appendingPathComponent("a.txt")
        let dstA = f.dst.appendingPathComponent("a.txt")
        f.stack.push(
            FileUndoRecord(
                action: .transferred(.move, [TransferredItem(source: srcA, destination: dstA)], replaced: []),
                title: "Move of “a.txt”"))

        await #expect(throws: UndoError.itemChanged(name: "a.txt")) { try await f.stack.undo() }
        #expect(f.stack.records.isEmpty)
    }

    @Test func undoRefusesPartlyBeforeTouchingAnything() async throws {
        // The second item is gone: the first one must not be moved back either.
        let f = try Fixture()
        let srcA = f.src.appendingPathComponent("a")
        let dstA = try f.tmp.file("dst/a", contents: "A")
        let srcB = f.src.appendingPathComponent("b")
        let dstB = f.dst.appendingPathComponent("b")
        f.stack.push(
            FileUndoRecord(
                action: .transferred(
                    .move,
                    [TransferredItem(source: srcA, destination: dstA), TransferredItem(source: srcB, destination: dstB)],
                    replaced: []),
                title: "Move of 2 Items"))

        await #expect(throws: UndoError.itemChanged(name: "b")) { try await f.stack.undo() }
        #expect(f.exists(dstA))
        #expect(!f.exists(srcA))
    }

    @Test func crossVolumeMoveBackCopiesThenDeletes() async throws {
        let f = try Fixture()
        let moved = try f.tmp.folder("dst/a 2")
        try f.write(moved.appendingPathComponent("inner.txt"), "inner")
        let original = f.src.appendingPathComponent("a")

        let message = FileUndoStack.moveBack(moved, to: original, allowRename: false)

        #expect(message == nil)
        #expect(try f.read(original.appendingPathComponent("inner.txt")) == "inner")
        #expect(!f.exists(moved))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.src.path) == ["a"])
    }

    @Test func crossVolumeMoveBackNeverReplaces() async throws {
        let f = try Fixture()
        let moved = try f.tmp.file("dst/a", contents: "moved")
        let original = try f.tmp.file("src/a", contents: "foreign")

        let message = FileUndoStack.moveBack(moved, to: original, allowRename: false)

        #expect(message != nil)
        #expect(try f.read(original) == "foreign")
        #expect(try f.read(moved) == "moved")
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.src.path) == ["a"])
    }

    @Test func undoStackLimit() throws {
        let f = try Fixture(limit: 2)
        let url = f.src.appendingPathComponent("x")
        for title in ["one", "two", "three"] {
            f.stack.push(FileUndoRecord(action: .created([url]), title: title))
        }
        #expect(f.stack.records.count == 2)
        #expect(f.stack.records.map(\.title) == ["two", "three"])
        #expect(f.stack.undoTitle == "three")
    }

    @Test func undoEmptyThrows() async throws {
        let f = try Fixture()
        await #expect(throws: UndoError.nothingToUndo) { try await f.stack.undo() }
    }
}
