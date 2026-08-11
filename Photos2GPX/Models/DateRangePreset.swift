import Foundation

/// Quick spans offered above the date pickers.
enum DateRangePreset: String, CaseIterable, Identifiable {
    case today
    case yesterday
    case last7Days
    case last30Days
    case thisMonth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .last7Days: "Last 7 days"
        case .last30Days: "Last 30 days"
        case .thisMonth: "This month"
        }
    }

    /// Resolves to a concrete interval in the user's calendar. All presets end at
    /// the end of the current day so a run recorded minutes ago is included.
    func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday)
            .map { $0.addingTimeInterval(-1) } ?? now

        switch self {
        case .today:
            return DateInterval(start: startOfToday, end: endOfToday)
        case .yesterday:
            let start = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
            return DateInterval(start: start, end: startOfToday.addingTimeInterval(-1))
        case .last7Days:
            let start = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
            return DateInterval(start: start, end: endOfToday)
        case .last30Days:
            let start = calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
            return DateInterval(start: start, end: endOfToday)
        case .thisMonth:
            let components = calendar.dateComponents([.year, .month], from: now)
            let start = calendar.date(from: components) ?? startOfToday
            return DateInterval(start: start, end: endOfToday)
        }
    }
}
