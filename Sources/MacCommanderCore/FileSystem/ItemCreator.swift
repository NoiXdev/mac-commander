import Foundation

public enum ItemCreator {
    public static func createFolder(in directory: URL) throws -> URL {
        let name = NameGenerator.uniqueName(base: "untitled folder", pathExtension: nil, in: directory)
        let url = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    public static func createEmptyFile(in directory: URL) throws -> URL {
        let name = NameGenerator.uniqueName(base: "untitled", pathExtension: "txt", in: directory)
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return url
    }
}
