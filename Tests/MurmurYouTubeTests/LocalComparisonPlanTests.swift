import Testing
@testable import MurmurYouTube

@Suite("Local comparison plan")
struct LocalComparisonPlanTests {
    @Test("comparison contains only local engines")
    func containsOnlyLocalEngines() {
        #expect(LocalComparisonParticipant.allCases.map(\.displayName) == ["Apple", "Parakeet"])
    }
}
