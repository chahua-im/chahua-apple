import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

enum MessageTextSizePreference {
    enum Option: Int, CaseIterable {
        case smallest = -2
        case smaller = -1
        case system = 0
        case larger = 1
        case largest = 2

        var title: LocalizedStringKey {
            switch self {
            case .smallest: "Smallest"
            case .smaller: "Smaller"
            case .system: "Default"
            case .larger: "Larger"
            case .largest: "Largest"
            }
        }

        var factor: CGFloat { 1 + CGFloat(rawValue) * 0.1 }
    }

    private static let scaleStorageKey = "messageTextScale"
    static let storageKey: String = {
        migrateLegacyValue(in: .standard)
        return scaleStorageKey
    }()
    static let defaultValue = Option.system.rawValue
    static let allowedValues = Option.smallest.rawValue...Option.largest.rawValue

    static func option(_ value: Int) -> Option {
        Option(rawValue: value) ?? .system
    }

    /// Default follows accessibility sizing; an explicit choice replaces it, not multiplies it.
    static func scaledSize(_ value: Int, systemSize: CGFloat, defaultSize: CGFloat) -> CGFloat {
        let selection = option(value)
        return selection == .system ? systemSize : defaultSize * selection.factor
    }

    static func migrateLegacyValue(in defaults: UserDefaults) {
        let legacyKey = "messageTextSize"
        guard defaults.object(forKey: legacyKey) != nil else { return }
        if defaults.object(forKey: scaleStorageKey) == nil {
            let legacySize = min(max(defaults.integer(forKey: legacyKey), 14), 18)
            let selection =
                Option.allCases.min {
                    abs($0.factor - CGFloat(legacySize) / 17)
                        < abs($1.factor - CGFloat(legacySize) / 17)
                } ?? .system
            defaults.set(selection.rawValue, forKey: scaleStorageKey)
        }
        defaults.removeObject(forKey: legacyKey)
    }

    #if os(macOS)
        static func scaledBodySize(_ value: Int) -> CGFloat {
            scaledSize(
                value, systemSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
                defaultSize: NSFont.systemFontSize)
        }
    #else
        static func scaledBodySize(_ value: Int, compatibleWith traits: UITraitCollection)
            -> CGFloat
        {
            scaledSize(
                value,
                systemSize: UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
                    .pointSize,
                defaultSize: 17)
        }
    #endif
}
