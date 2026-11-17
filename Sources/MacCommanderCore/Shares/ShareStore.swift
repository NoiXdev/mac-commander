import Foundation
import Observation

/// The saved network shares, persisted as JSON (`{"version":1,"shares":[…],"declined":[…]}`) in Application
/// Support. Loaded synchronously on init (a small local file); written off the main actor, atomically, in order
/// so the last write wins. Passwords are never stored here.
@MainActor @Observable
public final class ShareStore {
    public nonisolated static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacCommander", isDirectory: true)
            .appendingPathComponent("shares.json")
    }

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var writeTask: Task<Void, Never>?

    public private(set) var shares: [SavedShare] = []
    /// "Not Now" answers to the remember prompt.
    public private(set) var declinedRemountURLs: Set<ShareURL> = []
    /// Entries of the file's share list that couldn't be read (for example an address this version doesn't
    /// accept), kept as they were and written back after the readable shares, so they are never lost.
    @ObservationIgnored private var unreadableShares: [JSONValue] = []

    /// Set when the file couldn't be read or moved aside; nothing is written for the rest of the session so the
    /// original is never overwritten.
    public private(set) var persistenceError: String?

    @ObservationIgnored private let now: @Sendable () -> Date

    public init(fileURL: URL = ShareStore.defaultURL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
        load()
    }

    @discardableResult
    public func add(_ url: ShareURL, username: String?) -> SavedShare {
        let user = username.flatMap { $0.isEmpty ? nil : $0 }
        if var existing = share(matching: url) {
            if let user, existing.username != user {
                existing.username = user
                update(existing)
            }
            return existing
        }
        let share = SavedShare(url: url, username: user)
        shares.append(share)
        persist()
        return share
    }

    public func update(_ share: SavedShare) {
        guard let index = shares.firstIndex(where: { $0.id == share.id }) else { return }
        shares[index] = share
        persist()
    }

    public func remove(_ id: UUID) {
        shares.removeAll { $0.id == id }
        persist()
    }

    public func share(matching url: ShareURL) -> SavedShare? {
        shares.first { $0.url.matches(url) }
    }

    /// Whether the user already answered "Not Now" for this share (compared with `matches`, not `==`).
    public func isDeclined(_ url: ShareURL) -> Bool {
        declinedRemountURLs.contains { $0.matches(url) }
    }

    public func decline(_ url: ShareURL) {
        guard !isDeclined(url) else { return }
        declinedRemountURLs.insert(url)
        persist()
    }

    /// Waits until all pending writes have finished.
    public func flush() async {
        await writeTask?.value
    }

    // MARK: Persistence

    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    /// One element of the file's share list: a share, or the raw JSON of one that couldn't be decoded.
    private enum ShareEntry: Codable {
        case share(SavedShare)
        case unreadable(JSONValue)

        init(from decoder: Decoder) throws {
            if let share = try? SavedShare(from: decoder) {
                self = .share(share)
            } else {
                self = .unreadable(try JSONValue(from: decoder))
            }
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case .share(let share): try share.encode(to: encoder)
            case .unreadable(let raw): try raw.encode(to: encoder)
            }
        }
    }

    private struct FileModel: Decodable {
        var shares: [SavedShare]
        var unreadableShares: [JSONValue]
        var declined: [ShareURL]
        init(from decoder: Decoder) throws {
            enum Key: String, CodingKey { case shares, declined }
            let c = try decoder.container(keyedBy: Key.self)
            let entries = (try c.decodeIfPresent([Lossy<ShareEntry>].self, forKey: .shares) ?? []).compactMap(\.value)
            shares = entries.compactMap { if case .share(let share) = $0 { share } else { nil } }
            unreadableShares = entries.compactMap { if case .unreadable(let raw) = $0 { raw } else { nil } }
            declined = (try c.decodeIfPresent([Lossy<ShareURL>].self, forKey: .declined) ?? []).compactMap(\.value)
        }
    }

    private struct FileOutput: Encodable {
        let version = 1
        let shares: [ShareEntry]
        let declined: [ShareURL]
    }

    private func load() {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return
        } catch {
            persistenceError = error.localizedDescription
            return
        }
        do {
            let model = try JSONDecoder().decode(FileModel.self, from: data)
            shares = model.shares
            unreadableShares = model.unreadableShares
            declinedRemountURLs = Set(model.declined)
        } catch {
            moveCorruptFileAside()
        }
    }

    private func moveCorruptFileAside() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = fileURL.lastPathComponent + ".corrupt-" + formatter.string(from: now())
        let directory = fileURL.deletingLastPathComponent()
        var target = directory.appendingPathComponent(base)
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent("\(base)-\(counter)")
            counter += 1
        }
        do {
            try FileManager.default.moveItem(at: fileURL, to: target)
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    private func persist() {
        guard persistenceError == nil else { return }
        let output = FileOutput(
            shares: shares.map(ShareEntry.share) + unreadableShares.map(ShareEntry.unreadable), declined: declinedRemountURLs.sorted { $0.url.absoluteString < $1.url.absoluteString })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(output) else { return }
        let url = fileURL
        let previous = writeTask
        writeTask = Task {
            await previous?.value
            await Self.write(data, to: url)
        }
    }

    @concurrent
    private static func write(_ data: Data, to url: URL) async {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Any JSON value, for keeping a file entry this version can't read exactly as it was.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
