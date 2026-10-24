import ChahuaAPI
import Foundation

/// Mirrors the PWA's status precedence and exact last-seen precision.
enum UserPresenceDisplay {
    static func subtitle(
        _ presence: UserPresenceResponse, now: Date = .now,
        calendar: Calendar? = nil, locale: Locale = AppLanguage.selected.locale
    ) -> String {
        if presence.online { return AppLanguage.localized("Online") }
        if presence.away == true { return AppLanguage.localized("Away") }
        if let bucket = presence.lastSeenBucket {
            switch bucket {
            case .recently: return AppLanguage.localized("Last seen recently")
            case .withinWeek: return AppLanguage.localized("Last seen within a week")
            case .withinMonth: return AppLanguage.localized("Last seen within a month")
            case .longAgo: return AppLanguage.localized("Last seen a long time ago")
            }
        }
        guard let lastSeen = presence.lastSeenAt else {
            return AppLanguage.localized("Last seen a long time ago")
        }
        let minutes = Int(max(0, now.timeIntervalSince(lastSeen)) / 60)
        if minutes < 1 { return AppLanguage.localized("Last seen just now") }
        if minutes == 1 { return AppLanguage.localized("Last seen 1 minute ago") }
        if minutes < 60 { return AppLanguage.localized("Last seen \(minutes) minutes ago") }
        let hours = minutes / 60
        if hours == 1 { return AppLanguage.localized("Last seen 1 hour ago") }
        if hours < 12 { return AppLanguage.localized("Last seen \(hours) hours ago") }

        // JavaScript Date uses Gregorian local calendar days, not elapsed 24-hour windows.
        var localCalendar = calendar ?? Calendar(identifier: .gregorian)
        if calendar == nil { localCalendar.timeZone = .autoupdatingCurrent }
        let time = lastSeen.formatted(
            .verbatim(
                "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
                timeZone: localCalendar.timeZone, calendar: localCalendar))
        if localCalendar.isDate(lastSeen, inSameDayAs: now) {
            return AppLanguage.localized("Last seen today at \(time)")
        }
        if let yesterday = localCalendar.date(byAdding: .day, value: -1, to: now),
            localCalendar.isDate(lastSeen, inSameDayAs: yesterday)
        {
            return AppLanguage.localized("Last seen yesterday at \(time)")
        }
        var dateStyle = Date.FormatStyle(
            locale: locale, calendar: localCalendar, timeZone: localCalendar.timeZone
        ).month(.abbreviated).day()
        if localCalendar.component(.year, from: lastSeen)
            != localCalendar.component(.year, from: now)
        {
            dateStyle = dateStyle.year()
        }
        let date = lastSeen.formatted(dateStyle)
        return AppLanguage.localized("Last seen \(date) at \(time)")
    }
}
