import Testing
@testable import MacCommanderCore

@Suite struct CueSheetTests {
    @Test func parsesTracksModesAndIndexes() throws {
        let sheet = try CueSheet.parse("""
            REM comment
            FILE "Game.bin" BINARY
              TRACK 01 MODE2/2352
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                PREGAP 00:02:00
                INDEX 00 00:02:00
                INDEX 01 00:04:00
            """)
        #expect(sheet.tracks.count == 2)
        #expect(sheet.tracks[0].mode == .mode2_2352)
        #expect(sheet.tracks[0].file == "Game.bin")
        #expect(sheet.tracks[0].index01Frames == 0)
        #expect(sheet.tracks[0].nextStartFrames == 150)
        #expect(sheet.tracks[1].index01Frames == 300)
        #expect(sheet.tracks[1].nextStartFrames == nil)
        #expect(sheet.audioTrackCount == 1)
    }

    @Test func parsesUnquotedFileName() throws {
        let sheet = try CueSheet.parse("FILE game.bin BINARY\nTRACK 01 MODE1/2048\nINDEX 01 00:01:00\n")
        #expect(sheet.tracks[0].file == "game.bin")
        #expect(sheet.tracks[0].index01Frames == 75)
    }

    @Test func rejectsNoDataTrack() {
        #expect(throws: DiscImageError.noDataTrack) {
            try CueSheet.parse("FILE \"a.bin\" BINARY\nTRACK 01 AUDIO\nINDEX 01 00:00:00\n")
        }
    }
}
