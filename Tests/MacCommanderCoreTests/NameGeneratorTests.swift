import Testing
import Foundation
@testable import MacCommanderCore

@Suite(.english) struct NameGeneratorTests {
    @Test func firstNameIsPlain() throws {
        let dir = try TemporaryDirectory()
        #expect(NameGenerator.uniqueName(base: "untitled", pathExtension: "txt", in: dir.url) == "untitled.txt")
        #expect(NameGenerator.uniqueName(base: "untitled folder", pathExtension: nil, in: dir.url) == "untitled folder")
    }

    @Test func skipsTakenNames() throws {
        let dir = try TemporaryDirectory()
        try dir.file("untitled.txt")
        try dir.file("untitled 2.txt")
        #expect(NameGenerator.uniqueName(base: "untitled", pathExtension: "txt", in: dir.url) == "untitled 3.txt")
    }

    @Test func hiddenFileCountsAsTaken() throws {
        let dir = try TemporaryDirectory()
        try dir.file(".untitled")
        #expect(NameGenerator.uniqueName(base: ".untitled", pathExtension: nil, in: dir.url) == ".untitled 2")
    }

    @Test func danglingSymlinkCountsAsTaken() throws {
        let dir = try TemporaryDirectory()
        try FileManager.default.createSymbolicLink(
            atPath: dir.url.appendingPathComponent("untitled.txt").path, withDestinationPath: "/nonexistent/target")
        #expect(NameGenerator.uniqueName(base: "untitled", pathExtension: "txt", in: dir.url) == "untitled 2.txt")
    }

    @Test func copyNames() throws {
        let tmp = try TemporaryDirectory()
        try tmp.file("report.txt")
        #expect(NameGenerator.copyName(for: "report.txt", isDirectory: false, in: tmp.url) == "report copy.txt")
        try tmp.file("report copy.txt")
        #expect(NameGenerator.copyName(for: "report.txt", isDirectory: false, in: tmp.url) == "report copy 2.txt")
        // Duplicating a copy continues its number instead of stacking "copy copy".
        #expect(NameGenerator.copyName(for: "report copy.txt", isDirectory: false, in: tmp.url) == "report copy 2.txt")
        try tmp.folder("my.folder")
        #expect(NameGenerator.copyName(for: "my.folder", isDirectory: true, in: tmp.url) == "my.folder copy")
        #expect(NameGenerator.copyName(for: ".zshrc", isDirectory: false, in: tmp.url) == ".zshrc copy")
    }

    @Test func copyNameUsesTheLanguagesWord() throws {
        let tmp = try TemporaryDirectory()
        try tmp.file("Bericht.txt")
        L10n.$localeOverride.withValue("de") {
            #expect(NameGenerator.copyName(for: "Bericht.txt", isDirectory: false, in: tmp.url) == "Bericht Kopie.txt")
        }
    }

    @Test func copyNameContinuesAnEnglishCopyAfterASwitch() throws {
        let tmp = try TemporaryDirectory()
        L10n.$localeOverride.withValue("de") {
            #expect(NameGenerator.copyName(for: "report copy.txt", isDirectory: false, in: tmp.url) == "report Kopie 2.txt")
            #expect(NameGenerator.copyName(for: "report Kopie 3.txt", isDirectory: false, in: tmp.url) == "report Kopie 4.txt")
        }
    }

    /// Polish Finder joins the word with a hyphen and no space ("raport-kopia.txt"), then numbers with a space.
    @Test func polishCopyNameUsesAHyphen() throws {
        let tmp = try TemporaryDirectory()
        try tmp.file("raport.txt")
        L10n.$localeOverride.withValue("pl") {
            #expect(NameGenerator.copyName(for: "raport.txt", isDirectory: false, in: tmp.url) == "raport-kopia.txt")
        }
        try tmp.file("raport-kopia.txt")
        L10n.$localeOverride.withValue("pl") {
            #expect(NameGenerator.copyName(for: "raport.txt", isDirectory: false, in: tmp.url) == "raport-kopia 2.txt")
        }
    }

    @Test func polishCopyContinuesAFinderMadeCopy() throws {
        let tmp = try TemporaryDirectory()
        L10n.$localeOverride.withValue("pl") {
            #expect(
                NameGenerator.copyName(for: "raport-kopia.txt", isDirectory: false, in: tmp.url) == "raport-kopia 2.txt")
            #expect(
                NameGenerator.copyName(for: "raport-kopia 4.txt", isDirectory: false, in: tmp.url)
                    == "raport-kopia 5.txt")
        }
    }

    @Test func polishCopyContinuesAnEnglishCopy() throws {
        let tmp = try TemporaryDirectory()
        L10n.$localeOverride.withValue("pl") {
            #expect(NameGenerator.copyName(for: "report copy.txt", isDirectory: false, in: tmp.url) == "report-kopia 2.txt")
            #expect(
                NameGenerator.copyName(for: "report copy 3.txt", isDirectory: false, in: tmp.url) == "report-kopia 4.txt")
        }
    }

    @Test func polishCopyOfAFolderKeepsItsDots() throws {
        let tmp = try TemporaryDirectory()
        try tmp.folder("moje.dane")
        L10n.$localeOverride.withValue("pl") {
            #expect(NameGenerator.copyName(for: "moje.dane", isDirectory: true, in: tmp.url) == "moje.dane-kopia")
        }
        try tmp.folder("moje.dane-kopia")
        L10n.$localeOverride.withValue("pl") {
            #expect(NameGenerator.copyName(for: "moje.dane", isDirectory: true, in: tmp.url) == "moje.dane-kopia 2")
            #expect(NameGenerator.copyName(for: "moje.dane-kopia", isDirectory: true, in: tmp.url) == "moje.dane-kopia 2")
        }
    }

    @Test func frenchCopyName() throws {
        let tmp = try TemporaryDirectory()
        L10n.$localeOverride.withValue("fr") {
            #expect(NameGenerator.copyName(for: "rapport.txt", isDirectory: false, in: tmp.url) == "rapport copie.txt")
            #expect(NameGenerator.copyName(for: "rapport copie.txt", isDirectory: false, in: tmp.url) == "rapport copie 2.txt")
        }
    }

    /// The pattern's text around `%@` is matched literally: `(`, `+` and `.` are not regex syntax.
    @Test func copyPatternIsMatchedLiterally() throws {
        let tmp = try TemporaryDirectory()
        let pattern = "%@ (copy+.)"
        #expect(
            NameGenerator.copyName(for: "a.txt", isDirectory: false, in: tmp.url, copyPattern: pattern)
                == "a (copy+.).txt")
        #expect(
            NameGenerator.copyName(for: "a (copy+.).txt", isDirectory: false, in: tmp.url, copyPattern: pattern)
                == "a (copy+.) 2.txt")
        // Would match the unescaped regex ` (copy+.)`, which reads as " copy", more "y"s, then any character.
        #expect(
            NameGenerator.copyName(for: "a copyyX.txt", isDirectory: false, in: tmp.url, copyPattern: pattern)
                == "a copyyX (copy+.).txt")
    }

    @Test func copyPatternMayHaveAPrefix() throws {
        let tmp = try TemporaryDirectory()
        let pattern = "Copy of %@"
        #expect(
            NameGenerator.copyName(for: "a.txt", isDirectory: false, in: tmp.url, copyPattern: pattern) == "Copy of a.txt")
        #expect(
            NameGenerator.copyName(for: "Copy of a.txt", isDirectory: false, in: tmp.url, copyPattern: pattern)
                == "Copy of a 2.txt")
    }

    @Test func keepBothNames() throws {
        let tmp = try TemporaryDirectory()
        try tmp.file("report.txt")
        #expect(NameGenerator.keepBothName(for: "report.txt", isDirectory: false, in: tmp.url) == "report 2.txt")
        try tmp.file("report 2.txt")
        #expect(NameGenerator.keepBothName(for: "report 2.txt", isDirectory: false, in: tmp.url) == "report 3.txt")
        #expect(NameGenerator.keepBothName(for: "Ärger.md", isDirectory: false, in: tmp.url) == "Ärger.md")
    }

    /// A suffix at or beyond Int.max is not a number to continue from (it used to trap on `+ 1`).
    @Test func hugeNumericSuffixesDontOverflow() throws {
        let tmp = try TemporaryDirectory()
        let max = "9223372036854775807"
        let beyond = "99999999999999999999"
        try tmp.file("x \(max).txt")
        try tmp.file("x copy \(max).txt")
        #expect(NameGenerator.copyName(for: "x \(max).txt", isDirectory: false, in: tmp.url) == "x \(max) copy.txt")
        #expect(
            NameGenerator.copyName(for: "x copy \(max).txt", isDirectory: false, in: tmp.url)
                == "x copy \(max) copy.txt")
        #expect(
            NameGenerator.copyName(for: "x copy \(beyond).txt", isDirectory: false, in: tmp.url)
                == "x copy \(beyond) copy.txt")
        #expect(NameGenerator.keepBothName(for: "x \(max).txt", isDirectory: false, in: tmp.url) == "x \(max) 2.txt")
        try tmp.file("x \(beyond).txt")
        #expect(
            NameGenerator.keepBothName(for: "x \(beyond).txt", isDirectory: false, in: tmp.url) == "x \(beyond) 2.txt")
        // The largest number that still continues.
        let below = "9223372036854775806"
        try tmp.file("y \(below).txt")
        #expect(NameGenerator.keepBothName(for: "y \(below).txt", isDirectory: false, in: tmp.url) == "y \(max).txt")
    }
}
