import CryptoKit
import Foundation
import XCTest

@testable import chahua_apple

@MainActor
final class ConversationDisplayPreferencesTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        let name = "ConversationDisplayPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testFirstAccountImportsExplicitBooleansAndNeverReimports() {
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: "chat.list.showThreadsInMessages")
        defaults.set(true, forKey: "chat.timeline.showAllAvatars")
        defaults.set(false, forKey: "chat.timeline.showDmDetails")
        let preferences = ConversationDisplayPreferences(defaults: defaults, namespace: "backend")
        preferences.activate(uid: 1)
        let imported = ConversationDisplayValues(
            showThreadsInMessages: false, showAllAvatars: true, showDmDetails: false)
        XCTAssertEqual(preferences.values, imported)
        XCTAssertNil(defaults.object(forKey: "chat.timeline.showAllAvatars"))
        preferences.activate(uid: 2)
        XCTAssertEqual(preferences.values, ConversationDisplayValues())
        preferences.setShowAllAvatars(true, for: 2)
        preferences.activate(uid: 1)
        XCTAssertEqual(preferences.values, imported)
        defaults.set(true, forKey: "chat.list.showThreadsInMessages")
        let reopened = ConversationDisplayPreferences(defaults: defaults, namespace: "backend")
        reopened.activate(uid: 1)
        XCTAssertEqual(reopened.values, imported)
        reopened.activate(uid: 2)
        XCTAssertTrue(reopened.values.showAllAvatars)
        XCTAssertTrue(reopened.values.showThreadsInMessages)
    }

    func testInvalidLegacyValuesRemainAndAbsentFieldsUseBuiltIns() {
        let defaults = isolatedDefaults()
        defaults.set(1, forKey: "chat.list.showThreadsInMessages")
        defaults.set("true", forKey: "chat.timeline.showAllAvatars")
        let preferences = ConversationDisplayPreferences(defaults: defaults, namespace: "backend")
        preferences.activate(uid: 1)
        XCTAssertEqual(preferences.values, ConversationDisplayValues())
        XCTAssertEqual(defaults.object(forKey: "chat.list.showThreadsInMessages") as? Int, 1)
        XCTAssertEqual(defaults.string(forKey: "chat.timeline.showAllAvatars"), "true")
        XCTAssertNotNil(defaults.dictionary(forKey: "chat.display.preferences.v1")?["legacyOwner"])
    }

    func testScopedValuesWinMigrationAndOtherAccountsSurviveWrites() {
        let defaults = isolatedDefaults()
        let hash = SHA256.hash(data: Data("backend".utf8))
            .map { String(format: "%02x", $0) }.joined()
        defaults.set(
            [
                "accounts": [
                    "\(hash).1": ["showAllAvatars": false],
                    "\(hash).2": ["showDmDetails": false],
                ]
            ], forKey: "chat.display.preferences.v1")
        defaults.set(true, forKey: "chat.timeline.showAllAvatars")
        defaults.set(false, forKey: "chat.timeline.showDmDetails")
        let preferences = ConversationDisplayPreferences(defaults: defaults, namespace: "backend")
        preferences.activate(uid: 1)
        XCTAssertFalse(preferences.values.showAllAvatars)
        XCTAssertFalse(preferences.values.showDmDetails)
        preferences.setShowThreadsInMessages(false, for: 1)
        preferences.activate(uid: 2)
        XCTAssertFalse(preferences.values.showDmDetails)
        XCTAssertTrue(preferences.values.showThreadsInMessages)
        let otherBackend = ConversationDisplayPreferences(defaults: defaults, namespace: "other")
        otherBackend.activate(uid: 1)
        XCTAssertEqual(otherBackend.values, ConversationDisplayValues())
        otherBackend.setShowAllAvatars(true, for: 1)
        preferences.activate(uid: 1)
        XCTAssertFalse(preferences.values.showThreadsInMessages)
        XCTAssertFalse(preferences.values.showAllAvatars)
    }

    func testInactiveAndStaleSettersCannotChangeAccountValues() {
        let defaults = isolatedDefaults()
        let preferences = ConversationDisplayPreferences(defaults: defaults, namespace: "backend")
        preferences.setShowAllAvatars(true, for: 1)
        XCTAssertNil(defaults.dictionary(forKey: "chat.display.preferences.v1"))
        preferences.activate(uid: 1)
        preferences.setShowAllAvatars(true, for: 1)
        preferences.activate(uid: 2)
        preferences.setShowThreadsInMessages(false, for: 1)
        XCTAssertEqual(preferences.values, ConversationDisplayValues())
        preferences.activate(uid: nil)
        preferences.setShowAllAvatars(true, for: 2)
        XCTAssertNil(preferences.activeUID)
        XCTAssertEqual(preferences.values, ConversationDisplayValues())
        preferences.activate(uid: 1)
        XCTAssertTrue(preferences.values.showAllAvatars)
        XCTAssertTrue(preferences.values.showThreadsInMessages)
    }
}
