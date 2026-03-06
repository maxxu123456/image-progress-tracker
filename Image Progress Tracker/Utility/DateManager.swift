import Foundation

extension Date {
    private static let mediumStyle = Date.FormatStyle(date: .abbreviated, time: .omitted)
        .locale(Locale(identifier: "en_US"))

    /// Formats the date as medium style (e.g., "Jan 12, 2024").
    func toMediumString() -> String {
        formatted(Self.mediumStyle)
    }

    /// Returns the number of calendar days between this date and another date.
    /// Uses startOfDay to avoid sub-24h and DST edge cases.
    func daysBetween(_ other: Date) -> Int {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: self)
        let end = calendar.startOfDay(for: other)
        return abs(calendar.dateComponents([.day], from: start, to: end).day ?? 0)
    }
}
