import SwiftUI

enum TimestampStyle { case time, date, dateTime, relative }

struct TimestampView: View {
    let date: Date
    let style: TimestampStyle

    var body: some View {
        switch style {
        case .time: Text(date, format: .dateTime.hour().minute())
        case .date: Text(date, format: .dateTime.year().month().day())
        case .dateTime: Text(date, format: .dateTime.year().month().day().hour().minute())
        case .relative: Text(date, style: .relative)
        }
    }
}
