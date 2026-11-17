import Foundation

/// The network volumes mounted right now, by any app. Listing runs on the blocking-I/O queue
/// (`PathQueries.run`): resource values of a dead network mount can block.
public struct SystemVolumeLister: MountedVolumeLister {
    public init() {}

    public func mountedShares() async -> [MountedShare] {
        await PathQueries.run { Self.mountedSharesNow() }
    }

    static func mountedSharesNow() -> [MountedShare] {
        let keys: [URLResourceKey] = [.volumeURLForRemountingKey, .volumeIsLocalKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? []
        return shares(from: volumes.map { volume in
            let values = try? volume.resourceValues(forKeys: Set(keys))
            return (volume, values?.volumeIsLocal, values?.volumeURLForRemounting)
        })
    }

    /// Keeps volumes known to be non-local whose remount URL is a supported share URL.
    static func shares(from volumes: [(mountPoint: URL, isLocal: Bool?, remount: URL?)]) -> [MountedShare] {
        volumes.compactMap { volume in
            guard volume.isLocal == false, let remount = volume.remount,
                let url = ShareURL(remountURL: remount)
            else { return nil }
            return MountedShare(mountPoint: volume.mountPoint, url: url)
        }
    }
}
