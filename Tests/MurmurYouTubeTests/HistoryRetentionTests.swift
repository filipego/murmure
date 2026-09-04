import Foundation
import Testing
@testable import MurmurYouTube

@Suite("History retention")
struct HistoryRetentionTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("never keeps every completed dictation")
    func neverExpiresHistory() {
        #expect(HistoryRetentionPeriod.never.expiredIDs(in: sampleRuns(), now: now).isEmpty)
    }

    @Test("thirty days expires only older dictations")
    func thirtyDayRetention() {
        let expired = HistoryRetentionPeriod.thirtyDays.expiredIDs(
            in: sampleRuns(),
            now: now
        )

        #expect(expired == Set([sampleRuns()[0].id]))
    }

    @Test("every retention choice has a stable localized label")
    func retentionLabels() {
        #expect(HistoryRetentionPeriod.allCases.map(\.displayName) == [
            "Never",
            "1 week",
            "30 days",
            "6 months",
            "1 year",
        ])
    }

    private func sampleRuns() -> [DictationRun] {
        [
            DictationRun(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000081")!,
                date: now.addingTimeInterval(-31 * 86_400),
                engine: "Apple",
                audioSeconds: 1,
                processSeconds: 0.1,
                text: "Old"
            ),
            DictationRun(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000082")!,
                date: now.addingTimeInterval(-29 * 86_400),
                engine: "Apple",
                audioSeconds: 1,
                processSeconds: 0.1,
                text: "Recent"
            ),
        ]
    }
}
