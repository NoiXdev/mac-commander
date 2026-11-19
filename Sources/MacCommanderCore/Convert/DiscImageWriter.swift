import Foundation

/// Converts a BIN/CUE CD image to an ISO by extracting the 2048-byte user data of every data sector.
public enum DiscImageWriter {
    private static let chunkBytes = 1 << 20

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
        let first = min(track.index01Frames, totalSectors)
        let last = min(track.nextStartFrames ?? totalSectors, totalSectors)
        let count = max(0, last - first)

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
            if count == 0 { progress(1) }
            return zeroed
        } catch {
            try? sink.close()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private static func parseSheet(_ cue: URL) throws -> CueSheet {
        let data: Data
        do { data = try Data(contentsOf: cue) } catch { throw DiscImageError.unreadable(cue.lastPathComponent) }
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
