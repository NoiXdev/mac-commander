import Foundation
import Testing
@testable import MacCommanderCore

@Suite struct DiscImageWriterTests {
    /// A sector of `size` bytes with a position-dependent pattern (so a wrong offset changes the output),
    /// with `submode` at offset 18 when given.
    private func sector(_ size: Int, fill: UInt8, submode: UInt8? = nil) -> Data {
        var data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(fill) &* 31) })
        if let submode, size > 18 { data[18] = submode }
        return data
    }

    private func write(_ dir: TemporaryDirectory, bin: String = "game.bin", sectors: [Data],
                       cue: String) throws -> URL {
        try sectors.reduce(Data(), +).write(to: dir.url.appendingPathComponent(bin))
        return try dir.file("game.cue", contents: cue)
    }

    private func run(_ cue: URL, _ dir: TemporaryDirectory) async throws -> (Data, Int) {
        let out = dir.url.appendingPathComponent("out.iso")
        let zeroed = try await DiscImageWriter.writeISO(cue: cue, to: out, progress: { _ in })
        return (try Data(contentsOf: out), zeroed)
    }

    @Test func mode1_2352StripsHeaderAndECC() async throws {
        let dir = try TemporaryDirectory()
        let sectors = (0..<3).map { sector(2352, fill: UInt8($0 + 1)) }
        let cue = try write(dir, sectors: sectors, cue: "FILE \"game.bin\" BINARY\nTRACK 01 MODE1/2352\nINDEX 01 00:00:00\n")
        let (iso, zeroed) = try await run(cue, dir)
        #expect(iso.count == 6144)
        #expect(zeroed == 0)
        #expect(iso == sectors.reduce(Data()) { $0 + $1[16..<2064] })
    }

    @Test func mode1_2048CopiesVerbatim() async throws {
        let dir = try TemporaryDirectory()
        let sectors = (0..<2).map { sector(2048, fill: UInt8($0 + 7)) }
        let cue = try write(dir, sectors: sectors, cue: "FILE \"game.bin\" BINARY\nTRACK 01 MODE1/2048\nINDEX 01 00:00:00\n")
        let (iso, _) = try await run(cue, dir)
        #expect(iso == sectors.reduce(Data(), +))
    }

    @Test func mode2_2352Form1AndForm2() async throws {
        let dir = try TemporaryDirectory()
        let sectors = [sector(2352, fill: 1, submode: 0x08), sector(2352, fill: 2, submode: 0x20),
                       sector(2352, fill: 3, submode: 0x08)]
        let cue = try write(dir, sectors: sectors, cue: "FILE \"game.bin\" BINARY\nTRACK 01 MODE2/2352\nINDEX 01 00:00:00\n")
        let (iso, zeroed) = try await run(cue, dir)
        #expect(zeroed == 1)
        #expect(iso.count == 6144)
        #expect(iso[0..<2048].dropFirst(0).elementsEqual(sectors[0][24..<2072]))
        #expect(iso[2048..<4096] == Data(count: 2048))
        #expect(iso[4096..<6144].elementsEqual(sectors[2][24..<2072]))
    }

    @Test func mode2_2336Offset8() async throws {
        let dir = try TemporaryDirectory()
        let sectors = (0..<2).map { sector(2336, fill: UInt8($0 + 4)) }
        let cue = try write(dir, sectors: sectors, cue: "FILE \"game.bin\" BINARY\nTRACK 01 MODE2/2336\nINDEX 01 00:00:00\n")
        let (iso, _) = try await run(cue, dir)
        #expect(iso == sectors.reduce(Data()) { $0 + $1[8..<2056] })
    }

    @Test func stopsAtNextTrack() async throws {
        let dir = try TemporaryDirectory()
        let sectors = (0..<4).map { sector(2352, fill: UInt8($0 + 1)) }
        let cue = try write(dir, sectors: sectors, cue: """
            FILE "game.bin" BINARY
            TRACK 01 MODE1/2352
            INDEX 01 00:00:00
            TRACK 02 AUDIO
            INDEX 01 00:00:02
            """)
        let (iso, _) = try await run(cue, dir)
        #expect(iso.count == 2 * 2048)
    }

    @Test func refusesMultiFileDataTrack() async throws {
        let dir = try TemporaryDirectory()
        let cue = try write(dir, sectors: [sector(2352, fill: 1)], cue: """
            FILE "game.bin" BINARY
            TRACK 01 MODE1/2352
            INDEX 01 00:00:00
            FILE "game2.bin" BINARY
            TRACK 02 MODE1/2352
            INDEX 01 00:00:00
            """)
        await #expect(throws: DiscImageError.multipleDataFiles) { _ = try await run(cue, dir) }
    }

    @Test func missingBinNamed() async throws {
        let dir = try TemporaryDirectory()
        let cue = try dir.file("game.cue", contents: "FILE \"Game.bin\" BINARY\nTRACK 01 MODE1/2352\nINDEX 01 00:00:00\n")
        await #expect(throws: DiscImageError.missingBin("Game.bin")) { _ = try await run(cue, dir) }
    }

    @Test func caseInsensitiveBinName() async throws {
        let dir = try TemporaryDirectory()
        let cue = try write(dir, bin: "game.bin", sectors: [sector(2352, fill: 9)],
                            cue: "FILE \"GAME.BIN\" BINARY\nTRACK 01 MODE1/2352\nINDEX 01 00:00:00\n")
        let (iso, _) = try await run(cue, dir)
        #expect(iso.count == 2048)
    }

    @Test func refusesNonCueSource() async throws {
        let dir = try TemporaryDirectory()
        let bin = dir.url.appendingPathComponent("game.bin")
        try Data(count: 2352 * 4).write(to: bin)
        await #expect(throws: DiscImageError.notCueSheet("game.bin")) { _ = try await run(bin, dir) }
        expectNoOutput(dir)
    }

    @Test func oversizedCueIsUnreadable() async throws {
        let dir = try TemporaryDirectory()
        let header = "FILE \"game.bin\" BINARY\nTRACK 01 MODE1/2352\nINDEX 01 00:00:00\n"
        let cue = try write(dir, sectors: [sector(2352, fill: 1)],
                            cue: header + String(repeating: "REM padding\n", count: (1 << 20) / 12 + 1))
        await #expect(throws: DiscImageError.unreadable("game.cue")) { _ = try await run(cue, dir) }
        expectNoOutput(dir)
    }

    @Test func sizeMismatchRejected() async throws {
        let dir = try TemporaryDirectory()
        let cue = try write(dir, sectors: [Data(count: 2352 * 2 + 5)],
                            cue: "FILE \"game.bin\" BINARY\nTRACK 01 MODE1/2352\nINDEX 01 00:00:00\n")
        await #expect(throws: DiscImageError.sizeMismatch) { _ = try await run(cue, dir) }
        #expect(!FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("out.iso").path))
    }

    @Test func refusesExistingOutput() async throws {
        let dir = try TemporaryDirectory()
        let cue = try write(dir, sectors: [sector(2352, fill: 1)],
                            cue: "FILE \"game.bin\" BINARY\nTRACK 01 MODE1/2352\nINDEX 01 00:00:00\n")
        let out = try dir.file("out.iso", contents: "keep")
        await #expect(throws: (any Error).self) {
            _ = try await DiscImageWriter.writeISO(cue: cue, to: out, progress: { _ in })
        }
        #expect(try String(contentsOf: out, encoding: .utf8) == "keep")
    }

    private func expectNoOutput(_ dir: TemporaryDirectory) {
        #expect(!FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("out.iso").path))
    }

    @Test func indexPastEndOfFileRejected() async throws {
        let dir = try TemporaryDirectory()
        let cue = try write(dir, sectors: [sector(2352, fill: 1)],
                            cue: "FILE \"game.bin\" BINARY\nTRACK 01 MODE1/2352\nINDEX 01 00:00:01\n")
        await #expect(throws: DiscImageError.sizeMismatch) { _ = try await run(cue, dir) }
        expectNoOutput(dir)
    }

    @Test func truncatedBinRejected() async throws {
        let dir = try TemporaryDirectory()
        let cue = try write(dir, sectors: [sector(2352, fill: 1), sector(2352, fill: 2)], cue: """
            FILE "game.bin" BINARY
            TRACK 01 MODE1/2352
            INDEX 01 00:00:00
            TRACK 02 AUDIO
            INDEX 01 00:00:05
            """)
        await #expect(throws: DiscImageError.sizeMismatch) { _ = try await run(cue, dir) }
        expectNoOutput(dir)
    }

    @Test func emptyTrackRangeRejected() async throws {
        let dir = try TemporaryDirectory()
        let cue = try write(dir, sectors: (0..<3).map { sector(2352, fill: UInt8($0)) }, cue: """
            FILE "game.bin" BINARY
            TRACK 01 MODE1/2352
            INDEX 01 00:00:02
            TRACK 02 AUDIO
            INDEX 01 00:00:01
            """)
        await #expect(throws: DiscImageError.sizeMismatch) { _ = try await run(cue, dir) }
        expectNoOutput(dir)
    }

    @Test func cancellationRemovesPartialOutput() async throws {
        let dir = try TemporaryDirectory()
        // 2 MB of 2048-byte sectors = two 1 MB chunks.
        let cue = try write(dir, sectors: (0..<1024).map { sector(2048, fill: UInt8($0 & 0xFF)) },
                            cue: "FILE \"game.bin\" BINARY\nTRACK 01 MODE1/2048\nINDEX 01 00:00:00\n")
        let out = dir.url.appendingPathComponent("out.iso")
        let task = Task<Int, any Error> {
            try await DiscImageWriter.writeISO(cue: cue, to: out, progress: { fraction in
                if fraction > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        expectNoOutput(dir)
    }
}
