import Foundation

enum HistoryRetentionPeriod: String, CaseIterable, Codable, Sendable {
    case never
    case oneWeek
    case thirtyDays
    case sixMonths
    case oneYear

    var displayName: String {
        switch self {
        case .never: "Never"
        case .oneWeek: "1 week"
        case .thirtyDays: "30 days"
        case .sixMonths: "6 months"
        case .oneYear: "1 year"
        }
    }

    func expiredIDs(
        in runs: [DictationRun],
        now: Date,
        calendar: Calendar = .current
    ) -> Set<UUID> {
        guard let cutoff = cutoff(before: now, calendar: calendar) else { return [] }
        return Set(runs.lazy.filter { $0.date < cutoff }.map(\.id))
    }

    private func cutoff(before now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .never:
            nil
        case .oneWeek:
            calendar.date(byAdding: .day, value: -7, to: now)
        case .thirtyDays:
            calendar.date(byAdding: .day, value: -30, to: now)
        case .sixMonths:
            calendar.date(byAdding: .month, value: -6, to: now)
        case .oneYear:
            calendar.date(byAdding: .year, value: -1, to: now)
        }
    }
}
