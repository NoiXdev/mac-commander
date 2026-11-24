import Foundation

public enum ItemCreator {
    /// The new-folder name in the current language. Look it up on the caller's task, before any hop to a queue:
    /// a language pinned with `L10n.localeOverride` doesn't reach a GCD queue.
    public static var newFolderName: String { L10n.string("name.newFolder", "untitled folder") }

    public static func createFolder(in directory: URL) throws -> URL {
        try createFolder(in: directory, named: newFolderName)
    }

    /// `named` is the base name; a number is added when it is taken.
    public static func createFolder(in directory: URL, named: String) throws -> URL {
        for _ in 0..<100 {
            let name = NameGenerator.uniqueName(base: named, pathExtension: nil, in: directory)
            let url = directory.appendingPathComponent(name, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                return url
            } catch CocoaError.fileWriteFileExists {
                // The name was taken after it was chosen: pick the next one.
                continue
            }
        }
        throw POSIXError(.EEXIST)
    }

    public static func createEmptyFile(in directory: URL) throws -> URL {
        try createEmptyFile(in: directory, named: Preferences.builtInNewFileName)
    }

    /// `named` is split at the last dot unless that is the first character (`.env`, `Makefile` have no extension).
    public static func createEmptyFile(in directory: URL, named: String) throws -> URL {
        var base = named
        var pathExtension: String?
        if let dot = named.lastIndex(of: "."), dot != named.startIndex, named.index(after: dot) != named.endIndex {
            base = String(named[..<dot])
            pathExtension = String(named[named.index(after: dot)...])
        }
        for _ in 0..<100 {
            let name = NameGenerator.uniqueName(base: base, pathExtension: pathExtension, in: directory)
            let url = directory.appendingPathComponent(name)
            // O_EXCL: never overwrite a file that appeared after the name was chosen.
            let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if fd >= 0 {
                _ = close(fd) // freshly created empty file: nothing buffered, close failure is not actionable
                return url
            }
            let code = errno
            if code == EEXIST { continue }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        throw POSIXError(.EEXIST)
    }
}
