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
        return volumes.compactMap { volume in
            guard let values = try? volume.resourceValues(forKeys: Set(keys)),
                values.volumeIsLocal == false,
                let remount = values.volumeURLForRemounting,
                let url = ShareURL(remountURL: remount)
            else { return nil }
            return MountedShare(mountPoint: volume, url: url)
        }
    }
}
