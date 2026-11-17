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

    private struct FileModel: Decodable {
        var shares: [SavedShare]
        var declined: [ShareURL]
        init(from decoder: Decoder) throws {
            enum Key: String, CodingKey { case shares, declined }
            let c = try decoder.container(keyedBy: Key.self)
            shares = (try c.decodeIfPresent([Lossy<SavedShare>].self, forKey: .shares) ?? []).compactMap(\.value)
            declined = (try c.decodeIfPresent([Lossy<ShareURL>].self, forKey: .declined) ?? []).compactMap(\.value)
        }
    }

    private struct FileOutput: Encodable {
        let version = 1
        let shares: [SavedShare]
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
        let output = FileOutput(shares: shares, declined: declinedRemountURLs.sorted { $0.url.absoluteString < $1.url.absoluteString })
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
