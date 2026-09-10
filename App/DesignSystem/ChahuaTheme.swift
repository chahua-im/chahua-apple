import SwiftUI

enum ChahuaTheme {
    static let background = Color.clear
    static let secondaryBackground = Color.primary.opacity(0.06)
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let separator = Color.primary.opacity(0.18)
    static let accent = Color.accentColor
    static let destructive = Color.red

    static func conversationBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? .black
            : Color(.sRGB, red: 244.0 / 255, green: 245.0 / 255, blue: 248.0 / 255, opacity: 1)
    }

    enum ChatBubble {
        static let outgoingBackground = Color(.sRGB, red: 43.0 / 255, green: 122.0 / 255, blue: 205.0 / 255, opacity: 1)
        static let outgoingForeground: Color = .white

        static func incomingBackground(for colorScheme: ColorScheme) -> Color {
            let channel = colorScheme == .dark ? 26.0 / 255 : 1
            return Color(.sRGB, red: channel, green: channel, blue: channel, opacity: 1)
        }

        static func incomingForeground(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? .white : Color(.sRGB, red: 26.0 / 255, green: 26.0 / 255, blue: 26.0 / 255, opacity: 1)
        }
    }

    enum ChatList {
        // PWA primary and Ionic medium palette, including its dark-mode variant.
        static let primary = Color(.sRGB, red: 43.0 / 255, green: 122.0 / 255, blue: 205.0 / 255, opacity: 1)

        static func muted(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark
                ? Color(.sRGB, red: 152.0 / 255, green: 154.0 / 255, blue: 162.0 / 255, opacity: 1)
                : Color(.sRGB, red: 99.0 / 255, green: 100.0 / 255, blue: 105.0 / 255, opacity: 1)
        }
    }

    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xLarge: CGFloat = 24
        static let xxLarge: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
    }
}
