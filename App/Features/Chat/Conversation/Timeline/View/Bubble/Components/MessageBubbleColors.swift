import SwiftUI

func bubbleColorForUser(uid: Int32, dark: Bool) -> Color {
    let light = ["CA5650", "D87B29", "9B66DC", "50B232", "379EB8", "4E92CC", "CF5C95"]
    let darkPalette = ["D45246", "F68136", "6C61DF", "46BA43", "5CAFFA", "408ACF", "D95574"]
    var hash: Int32 = 0
    // Hash the stable decimal UID, not the mutable display name.
    for byte in String(uid).utf8 {
        hash = (hash &* 31) &+ Int32(byte)
    }
    let palette = dark ? darkPalette : light
    return bubbleColor(hex: palette[Int(abs(Int64(hash)) % Int64(palette.count))]) ?? .primary
}

func bubbleColor(hex: String) -> Color? {
    let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard value.count == 6 || value.count == 8, let number = UInt64(value, radix: 16) else { return nil }
    let rgb = value.count == 8 ? number >> 8 : number
    return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                 green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255,
                 opacity: value.count == 8 ? Double(number & 255) / 255 : 1)
}
