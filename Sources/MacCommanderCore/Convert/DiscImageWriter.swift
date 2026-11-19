import Foundation

/// Converts a BIN/CUE CD image to an ISO by extracting the 2048-byte user data of every data sector.
public enum DiscImageWriter {
    private static let chunkBytes = 1 << 20
    /// A larger "CUE sheet" is not one; it is never read whole.
    private static let maxCueBytes = 1 << 20

    /// Resolves the data track's BIN next to `cue` (exact name, then case-insensitive), writes the ISO to
    /// `output` (must not exist). Returns the number of MODE2 Form 2 sectors written as zeros.
    /// Checks `Task.isCancelled` between 1 MB chunks (throws CancellationError); `progress(0...1)`.
    /// A partial output is removed on any thrown error or cancellation.
    @concurrent public static func writeISO(
        cue: URL, to output: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Int {
        let sheet = try parseSheet(cue)
        guard let track = sheet.tracks.first(where: { $0.mode.isData }) else { throw DiscImageError.noDataTrack }
        if sheet.tracks.contains(where: { $0.mode.isData && $0.file != track.file }) {
            throw DiscImageError.multipleDataFiles
        }
        let bin = try resolveBin(named: track.file, beside: cue)

        let sectorSize = track.mode.sectorSize
        let attributes = try FileManager.default.attributesOfItem(atPath: bin.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize % sectorSize == 0 else { throw DiscImageError.sizeMismatch }
        let totalSectors = fileSize / sectorSize
        let first = track.index01Frames
        let last = track.nextStartFrames ?? totalSectors
        // A track that starts past the file, ends past it (truncated BIN) or is empty would give a broken ISO.
        guard first < totalSectors, last <= totalSectors, last > first else { throw DiscImageError.sizeMismatch }
        let count = last - first

        let descriptor = open(output.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: output.path])
        }
        let sink = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var zeroed = 0
        do {
            let source = try FileHandle(forReadingFrom: bin)
            defer { try? source.close() }
            try source.seek(toOffset: UInt64(first * sectorSize))
            let perChunk = max(1, chunkBytes / sectorSize)
            let dataOffset = track.mode.dataOffset
            let zeroSector = Data(count: 2048)
            var done = 0
            progress(0)
            while done < count {
                try Task.checkCancellation()
                let n = min(perChunk, count - done)
                guard let chunk = try source.read(upToCount: n * sectorSize), chunk.count == n * sectorSize else {
                    throw DiscImageError.unreadable(bin.lastPathComponent)
                }
                var out = Data(capacity: n * 2048)
                for index in 0..<n {
                    let start = chunk.startIndex + index * sectorSize
                    if track.mode == .mode2_2352, chunk[start + 18] & 0x20 != 0 {
                        out.append(zeroSector)
                        zeroed += 1
                    } else {
                        out.append(chunk[(start + dataOffset)..<(start + dataOffset + 2048)])
                    }
                }
                try sink.write(contentsOf: out)
                done += n
                progress(Double(done) / Double(count))
            }
            try sink.close()
            return zeroed
        } catch {
            try? sink.close()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private static func parseSheet(_ cue: URL) throws -> CueSheet {
        // A BIN whose CUE sheet vanished after the menu was built would otherwise be read into memory.
        guard cue.pathExtension.lowercased() == "cue" else { throw DiscImageError.notCueSheet(cue.lastPathComponent) }
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: cue)
            defer { try? handle.close() }
            data = try handle.read(upToCount: maxCueBytes + 1) ?? Data()
        } catch {
            throw DiscImageError.unreadable(cue.lastPathComponent)
        }
        guard data.count <= maxCueBytes else { throw DiscImageError.unreadable(cue.lastPathComponent) }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return try CueSheet.parse(text)
    }

    private static func resolveBin(named name: String, beside cue: URL) throws -> URL {
        let folder = cue.deletingLastPathComponent()
        let fileName = (name as NSString).lastPathComponent
        let exact = folder.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: exact.path) { return exact }
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        if let match = siblings.first(where: { $0.caseInsensitiveCompare(fileName) == .orderedSame }) {
            return folder.appendingPathComponent(match)
        }
        throw DiscImageError.missingBin(fileName)
    }
}
