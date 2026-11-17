import Foundation
import Testing

@testable import MacCommanderCore

@Suite struct VolumeProviderTests {
    @Test func bootVolumeFirst() {
        let volumes = VolumeProvider.localVolumes()
        #expect(volumes.first?.isBoot == true)
        #expect(volumes.first?.url.path == "/")
        #expect(volumes.filter(\.isBoot).count == 1)
    }

    @Test func notificationsDeclared() {
        #expect(VolumeProvider.didChangeNotifications.count == 3)
    }
}
