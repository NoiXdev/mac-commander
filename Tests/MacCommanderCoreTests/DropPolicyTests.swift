import Foundation
import Testing

@testable import MacCommanderCore

@Suite struct DropPolicyTests {
    private func layout() throws -> (TemporaryDirectory, dir: URL, sub: URL, src: URL, a: URL, other: URL) {
        let tmp = try TemporaryDirectory()
        let fm = FileManager.default
        let dir = tmp.url.appendingPathComponent("dir")
        let sub = dir.appendingPathComponent("sub")
        let src = tmp.url.appendingPathComponent("src")
        let other = tmp.url.appendingPathComponent("other")
        for d in [sub, src, other] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let a = src.appendingPathComponent("a")
        try Data().write(to: a)
        return (tmp, dir, sub, src, a, other)
    }

    @Test func volumeRulesAndModifiers() throws {
        let l = try layout()
        let same: (URL, URL) -> Bool = { _, _ in true }
        let different: (URL, URL) -> Bool = { _, _ in false }
        #expect(DropPolicy.operation(for: [l.a], into: l.other, modifiers: [], sameVolume: same) == .move)
        #expect(DropPolicy.operation(for: [l.a], into: l.other, modifiers: [], sameVolume: different) == .copy)
        #expect(DropPolicy.operation(for: [l.a], into: l.other, modifiers: .option, sameVolume: same) == .copy)
        #expect(DropPolicy.operation(for: [l.a], into: l.other, modifiers: .command, sameVolume: different) == .move)
        #expect(DropPolicy.operation(for: [l.a], into: l.other, modifiers: [.option, .command], sameVolume: same) == .copy)
    }

    @Test func refusesIntoItself() throws {
        let l = try layout()
        let same: (URL, URL) -> Bool = { _, _ in true }
        #expect(DropPolicy.operation(for: [l.dir], into: l.dir, modifiers: [], sameVolume: same) == nil)
        #expect(DropPolicy.operation(for: [l.dir], into: l.sub, modifiers: [], sameVolume: same) == nil)
        #expect(DropPolicy.operation(for: [l.dir], into: l.sub, modifiers: .option, sameVolume: same) == nil)
    }

    @Test func dropOnOwnParent() throws {
        let l = try layout()
        let same: (URL, URL) -> Bool = { _, _ in true }
        #expect(DropPolicy.operation(for: [l.a], into: l.src, modifiers: [], sameVolume: same) == nil)
        #expect(DropPolicy.operation(for: [l.a], into: l.src, modifiers: .command, sameVolume: same) == nil)
        #expect(DropPolicy.operation(for: [l.a], into: l.src, modifiers: .option, sameVolume: same) == .copy)
    }
}
