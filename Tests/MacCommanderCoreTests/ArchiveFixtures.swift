import Foundation

enum ArchiveFixtures {
    /// Writes `files` (relative path → contents; a value starting with "→" makes a symlink to the rest)
    /// into a fresh source folder and archives it with bsdtar. `format` is a bsdtar format name, or
    /// "tgz" for gzip-compressed ustar.
    static func makeArchive(
        _ files: [String: String], format: String, in temp: TemporaryDirectory, name: String? = nil
    ) throws -> URL {
        let src = try temp.folder("src-\(UUID().uuidString)")
        try writeTree(files, into: src)
        let ext = format == "tgz" ? "tgz" : format
        let out = temp.url.appendingPathComponent(name ?? "archive-\(UUID().uuidString).\(ext)")
        var arguments = ["-c", "-f", out.path]
        if format == "tgz" {
            arguments += ["-z", "--format", "ustar"]
        } else {
            arguments += ["--format", format]
        }
        arguments += ["-C", src.path, "."]
        try run("/usr/bin/bsdtar", arguments)
        return out
    }

    /// A zip whose file contents are encrypted with `password` (headers stay readable).
    static func makeEncryptedZip(
        _ files: [String: String], password: String, in temp: TemporaryDirectory
    ) throws -> URL {
        let src = try temp.folder("src-\(UUID().uuidString)")
        try writeTree(files, into: src)
        let out = temp.url.appendingPathComponent("encrypted-\(UUID().uuidString).zip")
        try run("/usr/bin/zip", ["-q", "-r", "-P", password, out.path, "."], in: src)
        return out
    }

    private static func writeTree(_ files: [String: String], into src: URL) throws {
        let fm = FileManager.default
        for (path, value) in files {
            let url = src.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if value.hasPrefix("→") {
                try fm.createSymbolicLink(atPath: url.path, withDestinationPath: String(value.dropFirst()))
            } else {
                try value.write(to: url, atomically: false, encoding: .utf8)
            }
        }
    }

    static func run(_ executable: String, _ arguments: [String], in directory: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "\(executable) failed"])
        }
    }
}
