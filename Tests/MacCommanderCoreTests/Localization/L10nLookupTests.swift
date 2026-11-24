import Testing

@testable import MacCommanderCore

@Suite struct L10nLookupTests {
    @Test(arguments: [("de", "Darstellung"), ("fr", "Présentation"), ("pl", "Widok")])
    func looksUpTheOverrideLanguage(language: String, title: String) {
        L10n.$localeOverride.withValue(language) {
            #expect(SettingsSection.view.title == title)
        }
    }

    @Test func fallsBackToTheEnglishArgumentForAnUnknownKey() {
        #expect(L10n.string("test.missing", "Fallback") == "Fallback")
        #expect(L10n.format("test.missing", "%1$@ in %2$@", "a", "b") == "a in b")
        #expect(L10n.plural("test.missing", count: 1, one: "%lld thing", other: "%lld things") == "1 thing")
        #expect(L10n.plural("test.missing", count: 2, one: "%lld thing", other: "%lld things") == "2 things")
    }

    @Test(.english) func pluralPicksEnglishForms() {
        #expect(L10n.plural("test.files", count: 1, one: "%lld file", other: "%lld files") == "1 file")
        #expect(L10n.plural("test.files", count: 3, one: "%lld file", other: "%lld files") == "3 files")
    }

    /// Two values a review caught: the German genitive "des Finders" and the French definite "Les éléments".
    @Test func grammarFixesInGermanAndFrench() {
        L10n.$localeOverride.withValue("de") {
            #expect(
                L10n.string("tags.error.standardTag", "Finder's color tags can't be renamed, recolored or deleted.")
                    == "Die Farb-Tags des Finders können nicht umbenannt, umgefärbt oder gelöscht werden.")
        }
        L10n.$localeOverride.withValue("fr") {
            #expect(
                L10n.string(
                    "operation.compress.differentFolders",
                    "Items can only be compressed together when they are in the same folder.")
                    == "Les éléments ne peuvent être compressés ensemble que s’ils se trouvent dans le même dossier.")
        }
    }

    @Test(.english) func englishTraitSetsTheOverride() {
        #expect(L10n.localeOverride == "en")
    }

    @Test func polishPluralForms() {
        L10n.$localeOverride.withValue("pl") {
            for (count, text) in [(1, "1 plik"), (2, "2 pliki"), (5, "5 plików"), (22, "22 pliki")] {
                #expect(L10n.plural("test.files", count: count, one: "%lld file", other: "%lld files") == text)
            }
        }
    }

    /// The tag counts of the rename and delete prompts. `TagActions` is in the app target, which tests can't import,
    /// so this looks the keys up with the same English the call sites pass.
    @Test(arguments: [
        (1, "Zmiana nazwy obejmie 1 plik.", "Usunięcie obejmie 1 plik."),
        (2, "Zmiana nazwy obejmie 2 pliki.", "Usunięcie obejmie 2 pliki."),
        (5, "Zmiana nazwy obejmie 5 plików.", "Usunięcie obejmie 5 plików."),
        (22, "Zmiana nazwy obejmie 22 pliki.", "Usunięcie obejmie 22 pliki."),
    ])
    func polishTagCountForms(count: Int, rename: String, delete: String) {
        L10n.$localeOverride.withValue("pl") {
            #expect(Self.tagRenameCount(count) == rename)
            #expect(Self.tagDeleteCount(count) == delete)
        }
    }

    @Test(.english) func englishTagCountForms() {
        #expect(Self.tagRenameCount(1) == "The tag is renamed on 1 file.")
        #expect(Self.tagRenameCount(3) == "The tag is renamed on 3 files.")
        #expect(Self.tagDeleteCount(1) == "It is removed from 1 file.")
        #expect(Self.tagDeleteCount(3) == "It is removed from 3 files.")
    }

    private static func tagRenameCount(_ count: Int) -> String {
        L10n.plural("tags.rename.files", count: count, one: "The tag is renamed on 1 file.", other: "The tag is renamed on %lld files.")
    }

    private static func tagDeleteCount(_ count: Int) -> String {
        L10n.plural("tags.delete.files", count: count, one: "It is removed from 1 file.", other: "It is removed from %lld files.")
    }

    /// The Quick Look and Compress items of the file list's context menu. `FileContextMenu` is in the app target,
    /// so this looks the keys up with the same English the call sites pass.
    @Test(arguments: [
        (1, "Szybki przegląd 1 rzeczy", "Kompresuj 1 rzecz"),
        (2, "Szybki przegląd 2 rzeczy", "Kompresuj 2 rzeczy"),
        (5, "Szybki przegląd 5 rzeczy", "Kompresuj 5 rzeczy"),
        (22, "Szybki przegląd 22 rzeczy", "Kompresuj 22 rzeczy"),
    ])
    func polishContextMenuCountForms(count: Int, quickLook: String, compress: String) {
        L10n.$localeOverride.withValue("pl") {
            #expect(Self.quickLookCount(count) == quickLook)
            #expect(Self.compressCount(count) == compress)
        }
    }

    @Test(.english) func englishContextMenuCountForms() {
        #expect(Self.quickLookCount(1) == "Quick Look 1 item")
        #expect(Self.quickLookCount(3) == "Quick Look 3 items")
        #expect(Self.compressCount(1) == "Compress 1 Item")
        #expect(Self.compressCount(3) == "Compress 3 Items")
    }

    private static func quickLookCount(_ count: Int) -> String {
        L10n.plural("fileList.menu.quickLook", count: count, one: "Quick Look 1 item", other: "Quick Look %lld items")
    }

    private static func compressCount(_ count: Int) -> String {
        L10n.plural("fileList.menu.compress", count: count, one: "Compress 1 Item", other: "Compress %lld Items")
    }

    /// The count strings of the operations, Convert, Get Info and the preview panel. Their call sites are in the app
    /// target, so these look the keys up with the same English the call sites pass.
    @Test(arguments: [
        (1, "1 rzecz nie mogła zostać przetworzona.", "1 nieczytelny sektor został zapisany jako zera."),
        (2, "2 rzeczy nie mogły zostać przetworzone.", "2 nieczytelne sektory zostały zapisane jako zera."),
        (5, "5 rzeczy nie mogło zostać przetworzonych.", "5 nieczytelnych sektorów zostało zapisanych jako zera."),
        (22, "22 rzeczy nie mogły zostać przetworzone.", "22 nieczytelne sektory zostały zapisane jako zera."),
    ])
    func polishOperationAlertCountForms(count: Int, itemsFailed: String, sectors: String) {
        L10n.$localeOverride.withValue("pl") {
            #expect(Self.itemsFailed(count) == itemsFailed)
            #expect(Self.zeroFilledSectors(count) == sectors)
        }
    }

    @Test(arguments: [
        (1, "„płyta.cue” ma 1 ścieżkę audio.", "Obraz ISO może zawierać tylko ścieżkę danych; ścieżka audio zostanie pominięta."),
        (2, "„płyta.cue” ma 2 ścieżki audio.", "Obraz ISO może zawierać tylko ścieżkę danych; ścieżki audio zostaną pominięte."),
        (5, "„płyta.cue” ma 5 ścieżek audio.", "Obraz ISO może zawierać tylko ścieżkę danych; ścieżki audio zostaną pominięte."),
        (22, "„płyta.cue” ma 22 ścieżki audio.", "Obraz ISO może zawierać tylko ścieżkę danych; ścieżki audio zostaną pominięte."),
    ])
    func polishAudioTrackForms(count: Int, title: String, leftOut: String) {
        L10n.$localeOverride.withValue("pl") {
            #expect(Self.audioTracks(count, "płyta.cue") == title)
            #expect(Self.audioTracksLeftOut(count) == leftOut)
        }
    }

    @Test(arguments: [
        (1, "0 z 1 pliku", "1 rzecz", "4 KB dla 1 rzeczy (4096 B)", "4 KB (1 B)"),
        (2, "0 z 2 plików", "2 rzeczy", "4 KB dla 2 rzeczy (4096 B)", "4 KB (2 B)"),
        (5, "0 z 5 plików", "5 rzeczy", "4 KB dla 5 rzeczy (4096 B)", "4 KB (5 B)"),
        (22, "0 z 22 plików", "22 rzeczy", "4 KB dla 22 rzeczy (4096 B)", "4 KB (22 B)"),
    ])
    func polishProgressInfoAndPreviewCountForms(count: Int, files: String, items: String, folder: String, file: String) {
        L10n.$localeOverride.withValue("pl") {
            #expect(Self.stripFiles(completed: 0, total: count) == files)
            #expect(Self.selectedItems(count) == items)
            #expect(Self.folderSize(count, bytes: "4 KB", byteCount: "4096") == folder)
            #expect(Self.fileSize(count, bytes: "4 KB", byteCount: "\(count)") == file)
        }
    }

    @Test(.english) func englishOperationInfoAndPreviewCountForms() {
        #expect(Self.itemsFailed(1) == "1 item couldn’t be processed.")
        #expect(Self.itemsFailed(3) == "3 items couldn’t be processed.")
        #expect(Self.zeroFilledSectors(1) == "1 unreadable sector was written as zeros.")
        #expect(Self.zeroFilledSectors(3) == "3 unreadable sectors were written as zeros.")
        #expect(Self.audioTracks(1, "disc.cue") == "“disc.cue” has 1 audio track.")
        #expect(Self.audioTracks(3, "disc.cue") == "“disc.cue” has 3 audio tracks.")
        #expect(Self.audioTracksLeftOut(1) == "An ISO can only hold the data track; the audio track will be left out.")
        #expect(Self.audioTracksLeftOut(3) == "An ISO can only hold the data track; the audio tracks will be left out.")
        #expect(Self.stripFiles(completed: 0, total: 1) == "0 of 1 file")
        #expect(Self.stripFiles(completed: 2, total: 3) == "2 of 3 files")
        #expect(Self.selectedItems(3) == "3 items")
        #expect(Self.folderSize(0, bytes: "Zero KB", byteCount: "0") == "Zero KB for 0 items (0 bytes)")
        #expect(Self.folderSize(1, bytes: "4 KB", byteCount: "4,096") == "4 KB for 1 item (4,096 bytes)")
        #expect(Self.folderSize(1_234, bytes: "9 MB", byteCount: "9,000,000", countText: "1,234") == "9 MB for 1,234 items (9,000,000 bytes)")
        #expect(Self.fileSize(1, bytes: "1 byte", byteCount: "1") == "1 byte (1 byte)")
        #expect(Self.fileSize(4_096, bytes: "4 KB", byteCount: "4,096") == "4 KB (4,096 bytes)")
    }

    /// French counts 0 as `one`: an empty folder must not read "1 élément".
    @Test func frenchEmptyFolderShowsItsCount() {
        L10n.$localeOverride.withValue("fr") {
            #expect(Self.folderSize(0, bytes: "Zéro Ko", byteCount: "0") == "Zéro Ko pour 0 élément (0 octets)")
            #expect(Self.fileSize(0, bytes: "Zéro Ko", byteCount: "0") == "Zéro Ko (0 octet)")
        }
    }

    private static func itemsFailed(_ count: Int) -> String {
        L10n.plural("operation.alert.itemsFailed", count: count, one: "1 item couldn’t be processed.", other: "%lld items couldn’t be processed.")
    }

    private static func zeroFilledSectors(_ count: Int) -> String {
        L10n.plural("convert.zeroFilledSectors", count: count, one: "1 unreadable sector was written as zeros.", other: "%lld unreadable sectors were written as zeros.")
    }

    private static func audioTracks(_ count: Int, _ name: String) -> String {
        L10n.plural("convert.audioTracks.title", count: count, one: "“%2$@” has 1 audio track.", other: "“%2$@” has %1$lld audio tracks.", name)
    }

    private static func audioTracksLeftOut(_ count: Int) -> String {
        L10n.plural("convert.audioTracks.leftOut", count: count, one: "An ISO can only hold the data track; the audio track will be left out.", other: "An ISO can only hold the data track; the audio tracks will be left out.")
    }

    private static func stripFiles(completed: Int, total: Int) -> String {
        L10n.plural("operation.strip.files", count: total, one: "%2$lld of 1 file", other: "%2$lld of %1$lld files", completed)
    }

    private static func selectedItems(_ count: Int) -> String {
        L10n.plural("preview.selection.items", count: count, one: "1 item", other: "%lld items")
    }

    private static func folderSize(_ count: Int, bytes: String, byteCount: String, countText: String? = nil) -> String {
        L10n.plural("info.size.folder", count: count, one: "%3$@ for 1 item (%4$@ bytes)", other: "%3$@ for %2$@ items (%4$@ bytes)", countText ?? "\(count)", bytes, byteCount)
    }

    private static func fileSize(_ count: Int, bytes: String, byteCount: String) -> String {
        L10n.plural("info.size.file", count: count, one: "%2$@ (1 byte)", other: "%2$@ (%3$@ bytes)", bytes, byteCount)
    }

    @Test func formatFillsPositionalPlaceholdersInTheTranslationsOrder() {
        L10n.$localeOverride.withValue("de") {
            #expect(L10n.format("test.location", "%1$@ is in %2$@.", "Bericht", "Dokumente") == "In Dokumente liegt Bericht.")
        }
    }
}

/// `.english` on a suite reaches each of its tests.
@Suite(.english) struct EnglishSuiteTraitTests {
    @Test func suiteTraitSetsTheOverride() {
        #expect(L10n.localeOverride == "en")
    }

    @Test(arguments: [1, 2]) func suiteTraitReachesEveryTestCase(_ value: Int) {
        #expect(L10n.localeOverride == "en")
    }
}
