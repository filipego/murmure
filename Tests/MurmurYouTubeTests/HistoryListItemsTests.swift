import Foundation
import Testing
@testable import MurmurYouTube

@Suite("History list items")
struct HistoryListItemsTests {
    @Test("date headers and dictations are flattened into lazy row order")
    func flattensDateGroups() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let newest = Date(timeIntervalSince1970: 2_000_000_000)
        let older = newest.addingTimeInterval(-86_400)
        let runs = [
            run(id: "00000000-0000-0000-0000-000000000091", date: newest),
            run(id: "00000000-0000-0000-0000-000000000092", date: newest.addingTimeInterval(-60)),
            run(id: "00000000-0000-0000-0000-000000000093", date: older),
        ]

        let items = HistoryListItems.make(fromNewestFirst: runs, calendar: calendar)

        #expect(items.map(\.id) == [
            .day(calendar.startOfDay(for: newest)),
            .run(runs[0].id),
            .run(runs[1].id),
            .day(calendar.startOfDay(for: older)),
            .run(runs[2].id),
        ])
    }

    private func run(id: String, date: Date) -> DictationRun {
        DictationRun(
            id: UUID(uuidString: id)!,
            date: date,
            engine: "Apple",
            audioSeconds: 1,
            processSeconds: 0.1,
            text: "Test"
        )
    }
}
