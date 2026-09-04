import Foundation

enum HistoryListItem: Identifiable {
    enum ID: Hashable {
        case day(Date)
        case run(UUID)
    }

    case day(Date, isFirst: Bool)
    case run(DictationRun)

    var id: ID {
        switch self {
        case .day(let date, _): .day(date)
        case .run(let run): .run(run.id)
        }
    }
}

enum HistoryListItems {
    static func make(
        fromNewestFirst runs: [DictationRun],
        calendar: Calendar = .current
    ) -> [HistoryListItem] {
        var currentDay: Date?
        var items: [HistoryListItem] = []
        items.reserveCapacity(runs.count * 2)

        for run in runs {
            let day = calendar.startOfDay(for: run.date)
            if day != currentDay {
                items.append(.day(day, isFirst: items.isEmpty))
                currentDay = day
            }
            items.append(.run(run))
        }

        return items
    }
}
