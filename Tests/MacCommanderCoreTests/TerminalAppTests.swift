import Foundation
import Testing

@testable import MacCommanderCore

@Suite struct TerminalAppTests {
    private func item(_ path: String, directory: Bool = false, package: Bool = false) -> FileItem {
        FileItem(
            url: URL(fileURLWithPath: path, isDirectory: directory), name: (path as NSString).lastPathComponent,
            isDirectory: directory, isPackage: package, isHidden: false,
            size: nil, dateModified: nil, dateCreated: nil, dateAdded: nil, kind: "")
    }

    @Test func foldersOpenThemselvesFilesTheirParent() {
        let folders = TerminalApp.folders(for: [
            item("/a/Projects", directory: true),
            item("/a/notes.md"),
            item("/a/b/report.pdf"),
            item("/a/b/other.txt"),
            // A package (an app bundle) is a file in the list: its parent opens.
            item("/Applications/Safari.app", package: true),
        ])
        #expect(folders.map(\.path) == ["/a/Projects", "/a", "/a/b", "/Applications"])
    }

    @Test func noChoiceUsesITermWhenInstalled() {
        #expect(TerminalApp.effective(chosen: nil, isInstalled: { _ in true }) == .iTerm)
        #expect(TerminalApp.effective(chosen: nil, isInstalled: { $0 == .terminal }) == .terminal)
    }

    @Test func choiceWinsUnlessUninstalled() {
        #expect(TerminalApp.effective(chosen: .terminal, isInstalled: { _ in true }) == .terminal)
        #expect(TerminalApp.effective(chosen: .iTerm, isInstalled: { _ in true }) == .iTerm)
        #expect(TerminalApp.effective(chosen: .iTerm, isInstalled: { $0 == .terminal }) == .terminal)
    }

    @Test func bundleIdentifiers() {
        #expect(TerminalApp.terminal.bundleIdentifier == "com.apple.Terminal")
        #expect(TerminalApp.iTerm.bundleIdentifier == "com.googlecode.iterm2")
    }
}
