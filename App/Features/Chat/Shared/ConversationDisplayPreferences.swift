import Combine
import CoreFoundation
import CryptoKit
import Foundation
import SwiftUI

struct ConversationDisplayValues: Equatable {
    var showThreadsInMessages = ConversationListPreferences.defaultShowThreadsInMessages
    var showAllAvatars = ConversationTimelinePreferences.defaultShowAllAvatars
    var showDmDetails = ConversationTimelinePreferences.defaultShowDmDetails
}

@MainActor
final class ConversationDisplayPreferences: ObservableObject {
    @Published private(set) var values = ConversationDisplayValues()
    private(set) var activeUID: Int32?
    private let defaults: UserDefaults
    private let namespaceHash: String
    private static let storageKey = "chat.display.preferences.v1"
    private static let legacyKeys = [
        "showThreadsInMessages": "chat.list.showThreadsInMessages",
        "showAllAvatars": "chat.timeline.showAllAvatars",
        "showDmDetails": "chat.timeline.showDmDetails",
    ]

    init(defaults: UserDefaults = .standard, namespace: String) {
        self.defaults = defaults
        namespaceHash = SHA256.hash(data: Data(namespace.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func activate(uid: Int32?) {
        activeUID = uid
        guard let uid else {
            values = ConversationDisplayValues()
            return
        }
        let id = accountID(uid)
        var root = defaults.dictionary(forKey: Self.storageKey) ?? [:]
        var accounts = root["accounts"] as? [String: [String: Any]] ?? [:]
        var account = accounts[id] ?? [:]
        if root["legacyOwner"] == nil {
            var captured: [String: Bool] = [:]
            for (field, key) in Self.legacyKeys {
                if let value = Self.boolean(defaults.object(forKey: key)) {
                    captured[key] = value
                    if Self.boolean(account[field]) == nil { account[field] = value }
                }
            }
            let migrated = Self.decode(account)
            accounts[id] = Self.encode(migrated)
            root["accounts"] = accounts
            root["legacyOwner"] = id
            // Persist ownership before cleanup. UserDefaults is not transactional;
            // the owner prevents a later launch/account from importing again.
            defaults.set(root, forKey: Self.storageKey)
            for (key, value) in captured where Self.boolean(defaults.object(forKey: key)) == value {
                defaults.removeObject(forKey: key)
            }
            values = migrated
        } else {
            values = Self.decode(account)
        }
    }

    func setShowThreadsInMessages(_ value: Bool, for uid: Int32) {
        set(value, key: "showThreadsInMessages", path: \.showThreadsInMessages, uid: uid)
    }

    func setShowAllAvatars(_ value: Bool, for uid: Int32) {
        set(value, key: "showAllAvatars", path: \.showAllAvatars, uid: uid)
    }

    func setShowDmDetails(_ value: Bool, for uid: Int32) {
        set(value, key: "showDmDetails", path: \.showDmDetails, uid: uid)
    }

    private func set(
        _ value: Bool, key: String, path: WritableKeyPath<ConversationDisplayValues, Bool>,
        uid: Int32
    ) {
        guard activeUID == uid, values[keyPath: path] != value else { return }
        var root = defaults.dictionary(forKey: Self.storageKey) ?? [:]
        var accounts = root["accounts"] as? [String: [String: Any]] ?? [:]
        let id = accountID(uid)
        var account = accounts[id] ?? Self.encode(values)
        account[key] = value
        accounts[id] = account
        root["accounts"] = accounts
        defaults.set(root, forKey: Self.storageKey)
        values[keyPath: path] = value
    }

    private func accountID(_ uid: Int32) -> String { "\(namespaceHash).\(uid)" }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    private static func decode(_ account: [String: Any]) -> ConversationDisplayValues {
        var result = ConversationDisplayValues()
        if let value = boolean(account["showThreadsInMessages"]) {
            result.showThreadsInMessages = value
        }
        if let value = boolean(account["showAllAvatars"]) { result.showAllAvatars = value }
        if let value = boolean(account["showDmDetails"]) { result.showDmDetails = value }
        return result
    }

    private static func encode(_ values: ConversationDisplayValues) -> [String: Any] {
        [
            "showThreadsInMessages": values.showThreadsInMessages,
            "showAllAvatars": values.showAllAvatars,
            "showDmDetails": values.showDmDetails,
        ]
    }
}

private struct ConversationDisplayValuesKey: EnvironmentKey {
    static let defaultValue = ConversationDisplayValues()
}

extension EnvironmentValues {
    var conversationDisplayValues: ConversationDisplayValues {
        get { self[ConversationDisplayValuesKey.self] }
        set { self[ConversationDisplayValuesKey.self] = newValue }
    }
}

struct ConversationDisplayPreferenceScope<Content: View>: View {
    @ObservedObject var preferences: ConversationDisplayPreferences
    @ViewBuilder var content: () -> Content

    var body: some View {
        content().environment(\.conversationDisplayValues, preferences.values)
    }
}
