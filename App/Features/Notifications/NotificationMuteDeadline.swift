import Foundation

/// Compact finite mute deadlines for the chat detail action tile.
enum NotificationMuteDeadline {
    // 9999-12-31 00:00:00 UTC is the server's maximum-date (indefinite mute) sentinel.
    private static let maximumMuteDate = Date(timeIntervalSince1970: 253_402_214_400)

    static func finiteDeadline(
        _ until: Date?, now: Date = .now, calendar: Calendar = .current
    ) -> String? {
        guard let until, until > now, until < maximumMuteDate else { return nil }
        return formattedDeadline(until, now: now, calendar: calendar)
    }

    private static func formattedDeadline(
        _ until: Date, now: Date = .now, calendar: Calendar = .current
    ) -> String {
        if calendar.isDate(until, inSameDayAs: now) {
            return until.formatted(
                .verbatim(
                    "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
                    timeZone: calendar.timeZone, calendar: calendar))
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
            calendar.isDate(until, inSameDayAs: tomorrow)
        {
            return AppLanguage.localized("tomorrow")
        }
        return until.formatted(
            .verbatim(
                "\(month: .twoDigits)/\(day: .twoDigits)",
                timeZone: calendar.timeZone, calendar: calendar))
    }
}
