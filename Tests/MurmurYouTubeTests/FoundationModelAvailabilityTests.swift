import Testing
@testable import MurmurYouTube

@Suite("Foundation model availability")
struct FoundationModelAvailabilityTests {
    @Test("model availability is queried only once per settings lifetime")
    @MainActor
    func availabilityLoadsOnce() {
        let availability = FoundationModelAvailabilityStore()
        var reasonQueryCount = 0
        var supportQueryCount = 0

        availability.loadIfNeeded(
            reasonQuery: {
                reasonQueryCount += 1
                return nil
            },
            supportsQuery: { _ in
                supportQueryCount += 1
                return true
            }
        )
        availability.loadIfNeeded(
            reasonQuery: {
                reasonQueryCount += 1
                return "unexpected second query"
            },
            supportsQuery: { _ in
                supportQueryCount += 1
                return false
            }
        )

        #expect(reasonQueryCount == 1)
        #expect(supportQueryCount == 3)
        #expect(availability.isAvailable)
        #expect(availability.supports(.english))
    }
}
