import Testing
@testable import MurmurYouTube

@Suite("CoreAudio input catalog")
struct CoreAudioInputCatalogTests {
    @Test("live snapshot contains only unique stable input identifiers")
    func liveSnapshot() throws {
        let snapshot = try CoreAudioInputCatalog().snapshot()
        let ids = snapshot.devices.map(\.id)

        #expect(Set(ids).count == ids.count)
        #expect(snapshot.devices.allSatisfy { !$0.id.isEmpty && !$0.displayName.isEmpty })
        #expect(snapshot.devices.filter(\.isSystemDefault).count <= 1)

        if let defaultDeviceID = snapshot.defaultDeviceID {
            #expect(ids.contains(defaultDeviceID))
        }
    }
}
