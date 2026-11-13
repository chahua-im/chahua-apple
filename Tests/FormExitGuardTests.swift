import Foundation
import XCTest

@testable import chahua_apple

@MainActor
final class FormExitGuardTests: XCTestCase {
    func testUnregisteredAndCleanFormsExitImmediately() {
        let guardController = FormExitGuard()
        var actions = 0
        guardController.requestExit { actions += 1 }
        guardController.update(
            owner: UUID(), isDirty: false, isSubmitting: false, accountID: 1, sessionRevision: 1)
        guardController.requestExit { actions += 1 }
        XCTAssertEqual(actions, 2)
        XCTAssertFalse(guardController.isProtected)
        XCTAssertFalse(guardController.showsDiscardConfirmation)
    }

    func testDirtyExitWaitsForConfirmationAndExecutesExactlyOnce() {
        let guardController = FormExitGuard()
        guardController.update(
            owner: UUID(), isDirty: true, isSubmitting: false, accountID: 1, sessionRevision: 1)
        var actions = 0
        guardController.requestExit { actions += 1 }
        XCTAssertTrue(guardController.isProtected)
        XCTAssertTrue(guardController.showsDiscardConfirmation)
        XCTAssertEqual(actions, 0)
        guardController.confirmDiscard()
        guardController.confirmDiscard()
        XCTAssertEqual(actions, 1)
        XCTAssertFalse(guardController.showsDiscardConfirmation)
    }

    func testKeepEditingCancelsOnlyTheFirstCoalescedAttempt() {
        let guardController = FormExitGuard()
        guardController.update(
            owner: UUID(), isDirty: true, isSubmitting: false, accountID: 1, sessionRevision: 1)
        var actions = 0
        var firstCancellations = 0
        var secondCancellations = 0
        guardController.requestExit({ actions += 1 }, onCancel: { firstCancellations += 1 })
        guardController.requestExit({ actions += 10 }, onCancel: { secondCancellations += 1 })
        guardController.cancelDiscard()
        guardController.cancelDiscard()
        guardController.confirmDiscard()
        XCTAssertEqual(actions, 0)
        XCTAssertEqual(firstCancellations, 1)
        XCTAssertEqual(secondCancellations, 0)
        XCTAssertTrue(guardController.isProtected)
        XCTAssertFalse(guardController.showsDiscardConfirmation)
        guardController.requestExit { actions += 100 }
        guardController.confirmDiscard()
        XCTAssertEqual(actions, 100)
    }

    func testRepeatedExitAttemptsKeepTheOriginalAction() {
        let guardController = FormExitGuard()
        guardController.update(
            owner: UUID(), isDirty: true, isSubmitting: false, accountID: 1, sessionRevision: 1)
        var actions: [Int] = []
        guardController.requestExit { actions.append(1) }
        guardController.requestExit { actions.append(2) }
        guardController.confirmDiscard()
        XCTAssertEqual(actions, [1])
    }

    func testSubmittingBlocksEvenCleanExitAndFailureRestoresDirtyDecision() {
        for isDirty in [false, true] {
            let guardController = FormExitGuard()
            let owner = UUID()
            guardController.update(
                owner: owner, isDirty: isDirty, isSubmitting: true, accountID: 1, sessionRevision: 1
            )
            var actions = 0
            guardController.requestExit { actions += 1 }
            guardController.confirmDiscard()
            XCTAssertTrue(guardController.isProtected)
            XCTAssertFalse(guardController.showsDiscardConfirmation)
            XCTAssertEqual(actions, 0)
            // A failed write leaves the draft dirty and ends only submission protection.
            guardController.update(
                owner: owner, isDirty: true, isSubmitting: false, accountID: 1, sessionRevision: 1)
            guardController.requestExit { actions += 1 }
            XCTAssertTrue(guardController.showsDiscardConfirmation)
            XCTAssertEqual(actions, 0)
            guardController.confirmDiscard()
            XCTAssertEqual(actions, 1)
        }
    }

    func testSubmissionStartingAfterPromptPreventsConfirmedExit() {
        let guardController = FormExitGuard()
        let owner = UUID()
        guardController.update(
            owner: owner, isDirty: true, isSubmitting: false, accountID: 1, sessionRevision: 1)
        var actions = 0
        guardController.requestExit { actions += 1 }
        guardController.update(
            owner: owner, isDirty: true, isSubmitting: true, accountID: 1, sessionRevision: 1)
        guardController.confirmDiscard()
        XCTAssertEqual(actions, 0)
        XCTAssertTrue(guardController.isProtected)
        XCTAssertFalse(guardController.showsDiscardConfirmation)
    }

    func testSuccessfulSaveClearsProtectionAndAllowsImmediateExit() {
        let guardController = FormExitGuard()
        let owner = UUID()
        guardController.update(
            owner: owner, isDirty: true, isSubmitting: true, accountID: 1, sessionRevision: 1)
        guardController.update(
            owner: owner, isDirty: false, isSubmitting: false, accountID: 1, sessionRevision: 1)
        var actions = 0
        guardController.requestExit { actions += 1 }
        XCTAssertEqual(actions, 1)
        XCTAssertFalse(guardController.isProtected)
        XCTAssertFalse(guardController.showsDiscardConfirmation)
    }

    func testAccountOwnerAndSessionChangesInvalidatePendingClosures() {
        let originalOwner = UUID()
        let replacements: [(UUID, Int32?, Int)] = [
            (UUID(), 1, 1), (originalOwner, 2, 1),
            (originalOwner, nil, 1), (originalOwner, 1, 2),
        ]
        for (owner, accountID, sessionRevision) in replacements {
            let guardController = FormExitGuard()
            guardController.update(
                owner: originalOwner, isDirty: true, isSubmitting: false,
                accountID: 1, sessionRevision: 1)
            var oldActions = 0
            var oldCancellations = 0
            guardController.requestExit(
                { oldActions += 1 }, onCancel: { oldCancellations += 1 })
            guardController.update(
                owner: owner, isDirty: true, isSubmitting: false,
                accountID: accountID, sessionRevision: sessionRevision)
            XCTAssertFalse(guardController.showsDiscardConfirmation)
            guardController.confirmDiscard()
            guardController.cancelDiscard()
            XCTAssertEqual(oldActions, 0)
            XCTAssertEqual(oldCancellations, 0)
            var newActions = 0
            guardController.requestExit { newActions += 1 }
            guardController.confirmDiscard()
            XCTAssertEqual(newActions, 1)
        }
    }

    func testStaleOwnerCannotUnregisterNewerForm() {
        let guardController = FormExitGuard()
        let oldOwner = UUID()
        let newOwner = UUID()
        guardController.update(
            owner: oldOwner, isDirty: true, isSubmitting: false, accountID: 1, sessionRevision: 1)
        guardController.update(
            owner: newOwner, isDirty: true, isSubmitting: false, accountID: 1, sessionRevision: 1)
        var actions = 0
        guardController.requestExit { actions += 1 }
        guardController.unregister(owner: oldOwner)
        XCTAssertTrue(guardController.isProtected)
        XCTAssertTrue(guardController.showsDiscardConfirmation)
        guardController.confirmDiscard()
        XCTAssertEqual(actions, 1)
        guardController.unregister(owner: newOwner)
        XCTAssertFalse(guardController.isProtected)
    }

    func testForcedInvalidationAndUnregistrationNeverRunPendingCallbacks() {
        for unregister in [false, true] {
            let guardController = FormExitGuard()
            let owner = UUID()
            guardController.update(
                owner: owner, isDirty: true, isSubmitting: false, accountID: 1, sessionRevision: 1)
            var callbacks = 0
            guardController.requestExit({ callbacks += 1 }, onCancel: { callbacks += 1 })
            if unregister {
                guardController.unregister(owner: owner)
            } else {
                guardController.invalidate()
            }
            guardController.confirmDiscard()
            guardController.cancelDiscard()
            XCTAssertEqual(callbacks, 0)
            XCTAssertFalse(guardController.isProtected)
            XCTAssertFalse(guardController.showsDiscardConfirmation)
        }
    }

    func testConfirmedActionCanSynchronouslyTearDownItsOwner() {
        let guardController = FormExitGuard()
        let owner = UUID()
        guardController.update(
            owner: owner, isDirty: true, isSubmitting: false, accountID: 1, sessionRevision: 1)
        var actions = 0
        guardController.requestExit {
            actions += 1
            guardController.unregister(owner: owner)
            guardController.confirmDiscard()
        }
        guardController.confirmDiscard()
        XCTAssertEqual(actions, 1)
        XCTAssertFalse(guardController.isProtected)
    }
}
