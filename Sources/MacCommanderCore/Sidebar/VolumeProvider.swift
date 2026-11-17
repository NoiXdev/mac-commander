import AppKit
import Foundation

public struct VolumeInfo: Identifiable, Hashable, Sendable {
    public let url: URL
    public var id: URL { url }
    public let name: String
    public let isEjectable: Bool
    public let isBoot: Bool
}

public enum VolumeProvider {
    public static let didChangeNotifications: [Notification.Name] = [
        NSWorkspace.didMountNotification,
        NSWorkspace.didUnmountNotification,
        NSWorkspace.didRenameVolumeNotification,
    ]

    /// Local, non-hidden mounted volumes with the boot volume first. Off the main actor: asking a mounted
    /// network volume for its resource values can block until its server answers.
    @concurrent
    public static func localVolumes() async -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeIsLocalKey, .volumeLocalizedNameKey, .volumeNameKey,
            .volumeIsEjectableKey, .volumeIsRemovableKey,
        ]
        let urls =
            FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let volumes: [VolumeInfo] = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                values.volumeIsLocal == true
            else { return nil }
            return VolumeInfo(
                url: url,
                name: values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent,
                isEjectable: (values.volumeIsEjectable ?? false) || (values.volumeIsRemovable ?? false),
                isBoot: url.standardizedFileURL.path == "/")
        }
        return volumes.filter(\.isBoot) + volumes.filter { !$0.isBoot }
    }
}
