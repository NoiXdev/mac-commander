import Foundation
import Testing
@testable import MacCommanderCore

struct ConvertCatalogTests {
    private static let installHint = "More formats need ffmpeg (brew install ffmpeg)"
    private static let reinstallHint = "ffmpeg is installed but doesn't start (brew reinstall ffmpeg)"
    private static let available = FFmpegStatus.available(URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"))

    private func menu(_ names: [String], _ ffmpeg: FFmpegStatus = .missing, cue: Bool = false) -> ConvertMenu {
        let urls = names.map { URL(fileURLWithPath: "/tmp/\($0)", isDirectory: $0.hasSuffix("/")) }
        return ConvertCatalog.menu(for: urls, ffmpeg: ffmpeg, cueExists: { _ in cue })
    }

    @Test func heicOffersImageTargetsExceptOwn() {
        let m = menu(["a.heic"])
        #expect(m.targets == [.jpeg, .png, .tiff])
        #expect(m.ffmpegHint == nil)
    }

    @Test func jpegAliasExcludesJPEG() {
        #expect(menu(["a.JPEG"]).targets == [.png, .heic, .tiff])
    }

    @Test func audioWithoutFFmpegShowsHint() {
        let m = menu(["a.wav"], .missing)
        #expect(m.targets == [.m4a, .aiff])
        #expect(m.ffmpegHint == Self.installHint)
    }

    @Test func audioWithBrokenFFmpegShowsReinstall() {
        let m = menu(["a.wav"], .broken)
        #expect(m.targets == [.m4a, .aiff])
        #expect(m.ffmpegHint == Self.reinstallHint)
    }

    @Test func audioWithFFmpegAddsMP3FLAC() {
        let m = menu(["a.wav"], Self.available)
        #expect(m.targets == [.m4a, .aiff, .mp3, .flac])
        #expect(m.ffmpegHint == nil)
    }

    @Test func mkvNeedsFFmpeg() {
        let missing = menu(["a.mkv"], .missing)
        #expect(missing.targets.isEmpty)
        #expect(missing.ffmpegHint == Self.installHint)
        #expect(menu(["a.mkv"], Self.available).targets == [.mp4FFmpeg])
    }

    @Test func nativeVideoExcludesSameContainer() {
        #expect(menu(["a.mp4"]).targets == [.movHEVC])
        #expect(menu(["a.mov"]).targets == [.mp4H264])
    }

    @Test func mixedSelectionIntersects() {
        let m = menu(["a.png", "b.mov"])
        #expect(m.targets.isEmpty)
        #expect(m.ffmpegHint == nil)
        #expect(menu(["a.txt", "b.docx"]).targets == [.docx, .rtf, .txt, .html, .pdf])
    }

    @Test func archivesTgzEqualsTarGz() {
        #expect(menu(["a.tgz"]).targets == [.zip, .sevenZip])
        #expect(menu(["a.tar.gz"]).targets == [.zip, .sevenZip])
        #expect(menu(["a.rar"]).targets == [.zip, .tarGz, .sevenZip])
    }

    @Test func binNeedsCue() {
        #expect(menu(["g.bin"], cue: false).targets.isEmpty)
        #expect(menu(["g.bin"], cue: true).targets == [.iso])
        #expect(menu(["g.cue"]).targets == [.iso])
    }

    @Test func binAndCueBecomeOneSource() {
        let bin = URL(fileURLWithPath: "/tmp/g.bin")
        let cue = URL(fileURLWithPath: "/tmp/g.cue")
        #expect(ConvertCatalog.sources(for: [bin, cue], cueExists: { _ in true }) == [cue])
        #expect(ConvertCatalog.sources(for: [bin], cueExists: { _ in true }) == [cue])
    }

    @Test func binAndCueDifferingInCaseBecomeOneSource() {
        let bin = URL(fileURLWithPath: "/tmp/G.BIN")
        let cue = URL(fileURLWithPath: "/tmp/g.cue")
        #expect(ConvertCatalog.sources(for: [bin, cue], cueExists: { _ in true }) == [cue])
        #expect(ConvertCatalog.sources(for: [cue, bin], cueExists: { _ in true }) == [cue])
    }

    @Test func unknownExtensionNoMenu() {
        #expect(menu(["a.xyz"]).targets.isEmpty)
        #expect(menu(["folder/"]).targets.isEmpty)
    }
}
