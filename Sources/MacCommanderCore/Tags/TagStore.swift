import Foundation

public enum TagChange: Sendable {
    case add(FileTag), remove(FileTag), replace([FileTag])
}

/// Reads and writes Finder tags, stored only in the `_kMDItemUserTags` extended attribute
/// as a binary plist array of `"name\ncolor"` strings.
public enum TagStore {
    public static let attributeName = "com.apple.metadata:_kMDItemUserTags"

    /// Pure parser. A string without a newline, or with an unparsable color, gets `.none`;
    /// non-string elements are skipped.
    public static func decode(_ data: Data) -> [FileTag] {
        guard let array = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [Any]
        else { return [] }
        return array.compactMap { element in
            guard let string = element as? String else { return nil }
            guard let newline = string.firstIndex(of: "\n") else {
                return FileTag(name: string, rawColor: 0)
            }
            let color = Int(string[string.index(after: newline)...]) ?? 0
            return FileTag(name: String(string[..<newline]), rawColor: color)
        }
    }

    public static func encode(_ tags: [FileTag]) -> Data {
        let strings = tags.map { "\($0.name)\n\($0.rawColor)" }
        return (try? PropertyListSerialization.data(fromPropertyList: strings, format: .binary, options: 0))
            ?? Data()
    }

    /// Blocking read. A missing or unreadable attribute gives `[]`.
    public static func readNow(_ url: URL) -> [FileTag] {
        url.withUnsafeFileSystemRepresentation { path -> [FileTag] in
            guard let path else { return [] }
            let size = getxattr(path, attributeName, nil, 0, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return [] }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes {
                getxattr(path, attributeName, $0.baseAddress, size, 0, XATTR_NOFOLLOW)
            }
            return read > 0 ? decode(data.prefix(read)) : []
        }
    }

    /// Blocking write. An empty list removes the attribute.
    public static func writeNow(_ tags: [FileTag], to url: URL) throws {
        let failure: Int32? = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return ENOENT }
            if tags.isEmpty {
                if removexattr(path, attributeName, XATTR_NOFOLLOW) != 0, errno != ENOATTR { return errno }
                return nil
            }
            let data = encode(tags)
            let result = data.withUnsafeBytes {
                setxattr(path, attributeName, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW)
            }
            return result == 0 ? nil : errno
        }
        if let failure { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
    }

    /// Applies `change` to each URL (read-modify-write, off the caller's thread). Add and remove keep
    /// every other entry exactly. URLs are processed in order; the first failure is thrown after the
    /// earlier URLs were already written.
    public static func setTags(_ change: TagChange, on urls: [URL]) async throws {
        try await PathQueries.run { () throws -> Void in
            for url in urls {
                let current = readNow(url)
                let updated: [FileTag]
                switch change {
                case .add(let tag):
                    updated = current.contains(tag) ? current : current + [tag]
                case .remove(let tag):
                    updated = current.filter { $0 != tag }
                case .replace(let tags):
                    updated = tags
                }
                if updated.count == current.count, zip(updated, current).allSatisfy({ $0.name == $1.name && $0.rawColor == $1.rawColor }) {
                    continue
                }
                try writeNow(updated, to: url)
            }
        }
    }
}
