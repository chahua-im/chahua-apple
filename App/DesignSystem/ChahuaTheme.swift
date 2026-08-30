import SwiftUI

enum ChahuaTheme {
    static let background = Color.clear
    static let secondaryBackground = Color.primary.opacity(0.06)
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let separator = Color.primary.opacity(0.18)
    static let accent = Color.accentColor
    static let destructive = Color.red

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
