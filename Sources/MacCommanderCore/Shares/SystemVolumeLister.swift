import Darwin
import Foundation

/// The network volumes mounted right now, by any app. Reads the kernel's mount table with
/// `getfsstat(MNT_NOWAIT)`, which returns the cached file-system information without asking any file system,
/// so a dead network mount can't block the listing. No per-volume file-system calls (`statfs`,
/// `getattrlist`, resource values) are made: the share address comes from the mount table's "mounted from"
/// string. Still runs on the blocking-I/O queue (`PathQueries.run`), like every system call here.
public struct SystemVolumeLister: MountedVolumeLister {
    public init() {}

    public func mountedShares() async -> [MountedShare] {
        await PathQueries.run { Self.mountedSharesNow() }
    }

    static func mountedSharesNow() -> [MountedShare] {
        shares(from: mountTable())
    }

    /// (file-system type, mounted from, mount point) of every mounted file system.
    private static func mountTable() -> [(fsType: String, mountFrom: String, mountPoint: String)] {
        // The count may grow between the two calls; a few spare entries catch that (getfsstat fills at most
        // the buffer and returns how many it filled).
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        var buffer: [statfs] = Array(repeating: .init(), count: Int(count) + 8)
        let filled = buffer.withUnsafeMutableBufferPointer { pointer in
            getfsstat(pointer.baseAddress, Int32(pointer.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard filled > 0 else { return [] }
        return buffer.prefix(Int(filled)).map { entry in
            (string(entry.f_fstypename), string(entry.f_mntfromname), string(entry.f_mntonname))
        }
    }

    /// A NUL-terminated C char array (imported as a tuple) as a String.
    private static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// Keeps the network file systems (smbfs, afpfs, nfs, webdav) whose "mounted from" string is a supported
    /// share address.
    static func shares(from table: [(fsType: String, mountFrom: String, mountPoint: String)]) -> [MountedShare] {
        table.compactMap { entry in
            guard let url = shareURL(fsType: entry.fsType, mountFrom: entry.mountFrom) else { return nil }
            return MountedShare(mountPoint: URL(fileURLWithPath: entry.mountPoint, isDirectory: true), url: url)
        }
    }

    /// The share address of one mount-table entry; nil for other file systems or an unreadable string.
    /// - smbfs: `//[DOMAIN;][user@]host[:port]/Share` (share name percent-encoded) → `smb://host/Share`.
    /// - afpfs: `afp://[user@]host/Share` or `//[user@]host/Share` → `afp://host/Share`.
    /// - nfs: `host:/path` (`[v6addr]:/path`) → `nfs://host/path`.
    /// - webdav: the http(s) URL as given.
    /// User names, domains and passwords are dropped (`ShareURL` never keeps credentials).
    static func shareURL(fsType: String, mountFrom: String) -> ShareURL? {
        switch fsType {
        case "smbfs":
            guard mountFrom.hasPrefix("//") else { return nil }
            return ShareURL("smb:" + mountFrom)
        case "afpfs":
            if mountFrom.lowercased().hasPrefix("afp://") { return ShareURL(mountFrom) }
            guard mountFrom.hasPrefix("//") else { return nil }
            return ShareURL("afp:" + mountFrom)
        case "nfs":
            return nfsURL(mountFrom)
        case "webdav":
            let lowercased = mountFrom.lowercased()
            guard lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") else { return nil }
            return ShareURL(mountFrom)
        default:
            return nil
        }
    }

    /// `host:/path` → `nfs://host/path`; the path is raw (not percent-encoded) in the mount table.
    private static func nfsURL(_ mountFrom: String) -> ShareURL? {
        let host: Substring
        let rest: Substring
        if mountFrom.hasPrefix("[") {
            guard let close = mountFrom.firstIndex(of: "]") else { return nil }
            host = mountFrom[...close]
            rest = mountFrom[mountFrom.index(after: close)...]
        } else {
            guard let colon = mountFrom.firstIndex(of: ":") else { return nil }
            host = mountFrom[..<colon]
            rest = mountFrom[colon...]
        }
        guard !host.isEmpty, rest.hasPrefix(":") else { return nil }
        var path = String(rest.dropFirst())
        if !path.hasPrefix("/") { path = "/" + path }
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return ShareURL("nfs://" + host + encoded)
    }
}
