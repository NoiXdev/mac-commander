import Foundation

public enum ItemCreator {
    public static func createFolder(in directory: URL) throws -> URL {
        for _ in 0..<100 {
            let name = NameGenerator.uniqueName(base: "untitled folder", pathExtension: nil, in: directory)
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
        for _ in 0..<100 {
            let name = NameGenerator.uniqueName(base: "untitled", pathExtension: "txt", in: directory)
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
