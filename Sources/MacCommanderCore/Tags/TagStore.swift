import Foundation

public enum TagChange: Sendable {
    case add(FileTag), remove(FileTag), replace([FileTag])
    /// Puts the second tag where the first one was (a new name or color); a file that has both keeps one.
    case rename(FileTag, to: FileTag)
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

    /// Names never carry a newline or other control character into the xattr (the newline separates
    /// name and color): each one becomes a space, then the name is trimmed. `encode` skips names that end up empty.
    public static func sanitizedName(_ name: String) -> String {
        // Only Cc and line breaks: format characters such as the emoji zero-width joiner stay.
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            let breaking = scalar.properties.generalCategory == .control || CharacterSet.newlines.contains(scalar)
            scalars.append(breaking ? " " : scalar)
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    public static func encode(_ tags: [FileTag]) -> Data {
        let strings = tags.compactMap { tag -> String? in
            let name = sanitizedName(tag.name)
            return name.isEmpty ? nil : "\(name)\n\(tag.rawColor)"
        }
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

    struct UndecodableTags: Error {}

    /// Blocking strict read for read-modify-write: only a missing attribute gives `[]`. Any other
    /// getxattr error, or data that isn't a plist array, throws so a write never drops existing tags.
    /// A size race (ERANGE, the attribute grew between the two calls) is retried once.
    static func readForWrite(_ url: URL) throws -> [FileTag] {
        for attempt in 0..<2 {
            let outcome: Result<Data?, POSIXError> = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return .failure(POSIXError(.ENOENT)) }
                let size = getxattr(path, attributeName, nil, 0, 0, XATTR_NOFOLLOW)
                if size < 0 {
                    return errno == ENOATTR ? .success(nil) : .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                }
                var data = Data(count: size)
                let read = data.withUnsafeMutableBytes {
                    getxattr(path, attributeName, $0.baseAddress, size, 0, XATTR_NOFOLLOW)
                }
                if read < 0 {
                    return errno == ENOATTR ? .success(nil) : .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                }
                return .success(data.prefix(read))
            }
            switch outcome {
            case .success(nil):
                return []
            case .success(let data?):
                guard (try? PropertyListSerialization.propertyList(from: data, format: nil)) is [Any]
                else { throw UndecodableTags() }
                return decode(data)
            case .failure(let error):
                if error.code == .ERANGE, attempt == 0 { continue }
                throw error
            }
        }
        throw POSIXError(.ERANGE)
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
                let current = try readForWrite(url)
                let updated: [FileTag]
                switch change {
                case .add(let tag):
                    updated = current.contains(tag) ? current : current + [tag]
                case .remove(let tag):
                    updated = current.filter { $0 != tag }
                case .replace(let tags):
                    updated = tags
                case .rename(let old, let new):
                    updated = current.reduce(into: []) { result, tag in
                        let mapped = tag == old ? new : tag
                        if let index = result.firstIndex(of: mapped) {
                            // The file had both: one entry stays, with the new name and color.
                            if tag == old { result[index] = new }
                        } else {
                            result.append(mapped)
                        }
                    }
                }
                if updated.count == current.count, zip(updated, current).allSatisfy({ $0.name == $1.name && $0.rawColor == $1.rawColor }) {
                    continue
                }
                try writeNow(updated, to: url)
            }
        }
    }
}
