import XCTest
@testable import DADFoundation

final class AccountPreferencesTests: XCTestCase {
    private func prefs() -> AccountPreferences {
        AccountPreferences(
            version: 3, referralEmails: true, marketingEmails: false, pushReferralConverted: true,
            pushStreakAtRisk: true, pushStreakMilestone: true, pushStreakLapsed: true,
            pushBadgeEarned: true, pushEventNearby: false, pushEventReminder: true,
            pushEventPromoted: false, pushGiftProcessed: true, rankingsOptedOut: false,
            networkVisible: true, volunteer: true)
    }

    func testAddingInterestTrimsAndMarksEdited() throws {
        let updated = try prefs().addingInterest("  Food drives \n").get()
        XCTAssertEqual(updated.volunteerInterests, ["Food drives"])
        XCTAssertTrue(updated.volunteerInterestsEdited)
        XCTAssertFalse(prefs().volunteerInterestsEdited)
    }

    func testAddingInterestRejectsBlankDuplicateOverlongAndFull() throws {
        let base = try prefs().addingInterest("Tutoring").get()
        XCTAssertEqual(try? XCTUnwrap(base.addingInterest("   ").failureValue), .empty)
        XCTAssertEqual(base.addingInterest("tutoring").failureValue, .duplicate, "dedupe ignores case")
        XCTAssertEqual(base.addingInterest(" Tutoring ").failureValue, .duplicate, "dedupe applies after trimming")
        XCTAssertEqual(base.addingInterest(String(repeating: "x", count: 61)).failureValue, .tooLong)
        XCTAssertNotNil(try? base.addingInterest(String(repeating: "x", count: 60)).get())
        var full = prefs()
        for index in 0..<AccountPreferences.maxInterests { full = try full.addingInterest("Interest \(index)").get() }
        XCTAssertEqual(full.volunteerInterests.count, 20)
        XCTAssertEqual(full.addingInterest("One more").failureValue, .full)
    }

    func testRemovingInterest() throws {
        let base = try prefs().addingInterest("A").get().addingInterest("B").get()
        let removed = base.removingInterest("A")
        XCTAssertEqual(removed.volunteerInterests, ["B"])
        XCTAssertTrue(removed.volunteerInterestsEdited)
        XCTAssertEqual(prefs().removingInterest("missing"), prefs(), "removing an unknown interest changes nothing")
    }

    func testWithFlipsTheRightToggle() {
        XCTAssertTrue(prefs().with("marketing_emails", true).marketingEmails)
        XCTAssertFalse(prefs().with("push_event_reminder", false).pushEventReminder)
        XCTAssertEqual(prefs(), prefs().with("nonexistent", true)) // unknown key is a no-op
    }

    func testPushTogglesExcludePaymentFailure() {
        let keys = prefs().pushToggles.map(\.key)
        XCTAssertEqual(keys.count, 9)
        XCTAssertFalse(keys.contains { $0.contains("payment") })
        XCTAssertTrue(keys.contains("push_streak_at_risk"))
    }

    func testShowRankingInvertsOptedOut() {
        var p = prefs()
        XCTAssertTrue(p.showRanking)
        p = p.with("rankings_opted_out", true)
        XCTAssertFalse(p.showRanking)
    }
}

final class DeleteAccountGateTests: XCTestCase {
    func testRequiresExactWord() {
        XCTAssertFalse(DeleteAccountGate(typed: "delete").isConfirmed) // case-sensitive
        XCTAssertFalse(DeleteAccountGate(typed: "").isConfirmed)
        XCTAssertFalse(DeleteAccountGate(typed: "DELETE ").isConfirmed)
        XCTAssertTrue(DeleteAccountGate(typed: "DELETE").isConfirmed)
    }
}

@MainActor
final class AccountSettingsModelTests: XCTestCase {
    private final class FakeService: AccountSettingsService, @unchecked Sendable {
        var failLoad = false
        var failSave = false
        var failDelete = false
        var blockDelete = false
        var failSignOut = false
        private(set) var deleted = false
        private(set) var didSignOut = false
        private(set) var lastSaved: AccountPreferences?
        private var prefs = AccountPreferences(
            version: 3, referralEmails: true, marketingEmails: false, pushReferralConverted: true,
            pushStreakAtRisk: true, pushStreakMilestone: true, pushStreakLapsed: true,
            pushBadgeEarned: true, pushEventNearby: false, pushEventReminder: true,
            pushEventPromoted: false, pushGiftProcessed: true, rankingsOptedOut: false,
            networkVisible: true, volunteer: true)
        private func snap() -> AccountSettingsSnapshot {
            AccountSettingsSnapshot(
                profile: AccountProfileSummary(email: "d@x.com", accountRole: "DONOR", zip: "78701", city: "Austin", phone: nil),
                preferences: prefs)
        }
        func load() async throws -> AccountSettingsSnapshot {
            if failLoad { throw AccountError.signedOut }
            return snap()
        }
        func savePreferences(_ preferences: AccountPreferences) async throws -> AccountSettingsSnapshot {
            if failSave { throw AccountError.unavailable }
            lastSaved = preferences
            prefs = AccountPreferences(
                version: preferences.version + 1, referralEmails: preferences.referralEmails,
                marketingEmails: preferences.marketingEmails, pushReferralConverted: preferences.pushReferralConverted,
                pushStreakAtRisk: preferences.pushStreakAtRisk, pushStreakMilestone: preferences.pushStreakMilestone,
                pushStreakLapsed: preferences.pushStreakLapsed, pushBadgeEarned: preferences.pushBadgeEarned,
                pushEventNearby: preferences.pushEventNearby, pushEventReminder: preferences.pushEventReminder,
                pushEventPromoted: preferences.pushEventPromoted, pushGiftProcessed: preferences.pushGiftProcessed,
                rankingsOptedOut: preferences.rankingsOptedOut, networkVisible: preferences.networkVisible,
                volunteer: preferences.volunteer, volunteerInterests: preferences.volunteerInterests)
            return snap()
        }
        func deleteAccount() async throws {
            if failDelete { throw AccountError.unavailable }
            if blockDelete { throw AccountError.deletionBlocked }
            deleted = true
        }
        func signOut() async throws {
            didSignOut = true
            if failSignOut { throw AccountError.unavailable }
        }
    }

    func testLoadReadySetsSnapshot() async {
        let model = AccountSettingsModel(service: FakeService())
        await model.load()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.snapshot?.profile.zip, "78701")
    }

    func testLoadFailureSurfacesFailed() async {
        let svc = FakeService(); svc.failLoad = true
        let model = AccountSettingsModel(service: svc)
        await model.load()
        guard case .failed = model.phase else { return XCTFail("expected failed") }
    }

    func testToggleSavesAndBumpsVersion() async {
        let model = AccountSettingsModel(service: FakeService())
        await model.load()
        XCTAssertEqual(model.snapshot?.preferences.version, 3)
        await model.toggle("marketing_emails", true)
        XCTAssertEqual(model.snapshot?.preferences.version, 4)
        XCTAssertTrue(model.snapshot!.preferences.marketingEmails)
    }

    func testAddAndRemoveInterestSaveThroughThePreferencesPath() async {
        let svc = FakeService()
        let model = AccountSettingsModel(service: svc)
        await model.load()
        let added = await model.addInterest(" Tutoring ")
        XCTAssertTrue(added)
        XCTAssertEqual(model.snapshot?.preferences.volunteerInterests, ["Tutoring"])
        XCTAssertEqual(model.snapshot?.preferences.version, 4)
        XCTAssertEqual(svc.lastSaved?.version, 3, "the save carries the version it read")
        XCTAssertTrue(svc.lastSaved?.volunteerInterestsEdited == true)
        await model.removeInterest("Tutoring")
        XCTAssertEqual(model.snapshot?.preferences.volunteerInterests, [])
        XCTAssertEqual(model.snapshot?.preferences.version, 5)
    }

    func testRejectedInterestSavesNothingAndExplains() async {
        let svc = FakeService()
        let model = AccountSettingsModel(service: svc)
        await model.load()
        let added = await model.addInterest("   ")
        XCTAssertFalse(added)
        XCTAssertNil(svc.lastSaved)
        XCTAssertEqual(model.interestError, AccountPreferences.InterestError.empty.message)
    }

    func testFailedInterestSaveKeepsTheListAndSurfacesError() async {
        let svc = FakeService()
        let model = AccountSettingsModel(service: svc)
        await model.load()
        svc.failSave = true
        let added = await model.addInterest("Tutoring")
        XCTAssertFalse(added)
        XCTAssertEqual(model.snapshot?.preferences.volunteerInterests, [])
        XCTAssertNotNil(model.actionError)
        XCTAssertFalse(model.isBusy)
    }

    func testTogglingLeavesInterestsOutOfTheSave() async {
        let svc = FakeService()
        let model = AccountSettingsModel(service: svc)
        await model.load()
        await model.toggle("marketing_emails", true)
        XCTAssertEqual(svc.lastSaved?.volunteerInterestsEdited, false)
    }

    func testDeleteRequiresConfirmThenWipes() async {
        let svc = FakeService()
        let model = AccountSettingsModel(service: svc)
        await model.load()
        // Unconfirmed: no-op with an error, nothing deleted.
        await model.deleteAccount(DeleteAccountGate(typed: "nope"))
        XCTAssertFalse(svc.deleted)
        XCTAssertFalse(model.signedOut)
        // Confirmed: deletes then wipes.
        await model.deleteAccount(DeleteAccountGate(typed: "DELETE"))
        XCTAssertTrue(svc.deleted)
        XCTAssertTrue(svc.didSignOut)
        XCTAssertTrue(model.signedOut)
    }

    func testSignOutWipes() async {
        let svc = FakeService()
        let model = AccountSettingsModel(service: svc)
        await model.load()
        await model.signOut()
        XCTAssertTrue(svc.didSignOut)
        XCTAssertTrue(model.signedOut)
    }

    func testFailedToggleKeepsSnapshotAndSurfacesError() async {
        let svc = FakeService()
        let model = AccountSettingsModel(service: svc)
        await model.load()
        svc.failSave = true
        await model.toggle("marketing_emails", true)
        XCTAssertEqual(model.snapshot?.preferences.version, 3)
        XCTAssertFalse(model.snapshot!.preferences.marketingEmails)
        XCTAssertEqual(model.actionError, "Something went wrong. Please try again.")
        XCTAssertFalse(model.isBusy)
    }

    func testFailedDeleteKeepsDonorSignedInWithoutWipingSession() async {
        let svc = FakeService(); svc.failDelete = true
        let model = AccountSettingsModel(service: svc)
        await model.load()
        await model.deleteAccount(DeleteAccountGate(typed: "DELETE"))
        XCTAssertFalse(svc.deleted)
        XCTAssertFalse(svc.didSignOut, "a failed delete must not log the donor out of an intact account")
        XCTAssertFalse(model.signedOut)
        XCTAssertNotNil(model.actionError)
        XCTAssertFalse(model.isBusy)
    }

    func testDeleteBlockedByAnActiveGiftOffersTheCancelPathAndRetryClearsIt() async {
        let svc = FakeService(); svc.blockDelete = true
        let model = AccountSettingsModel(service: svc)
        await model.load()
        await model.deleteAccount(DeleteAccountGate(typed: "DELETE"))
        XCTAssertTrue(model.deletionBlocked)
        XCTAssertTrue(model.actionError?.contains("Cancel your monthly gift first") == true)
        XCTAssertFalse(model.signedOut)
        XCTAssertFalse(svc.didSignOut, "a blocked delete leaves the session untouched")
        svc.blockDelete = false   // the gift was cancelled in the meantime
        await model.deleteAccount(DeleteAccountGate(typed: "DELETE"))
        XCTAssertFalse(model.deletionBlocked)
        XCTAssertTrue(model.signedOut)
        XCTAssertTrue(svc.deleted)
    }

    func testOtherDeleteFailuresDoNotOfferTheCancelPath() async {
        let svc = FakeService(); svc.failDelete = true
        let model = AccountSettingsModel(service: svc)
        await model.load()
        await model.deleteAccount(DeleteAccountGate(typed: "DELETE"))
        XCTAssertFalse(model.deletionBlocked)
    }

    func testDeleteLeavesTheShellEvenWhenRemoteLogoutFailsAfterward() async {
        let svc = FakeService(); svc.failSignOut = true
        let model = AccountSettingsModel(service: svc)
        await model.load()
        await model.deleteAccount(DeleteAccountGate(typed: "DELETE"))
        XCTAssertTrue(svc.deleted)
        XCTAssertTrue(model.signedOut, "the account no longer exists, so the donor cannot be left in the shell")
        XCTAssertNil(model.actionError)
    }

    func testFailedSignOutStaysInShellWithError() async {
        let svc = FakeService(); svc.failSignOut = true
        let model = AccountSettingsModel(service: svc)
        await model.load()
        await model.signOut()
        XCTAssertFalse(model.signedOut)
        XCTAssertNotNil(model.actionError)
    }

    func testZipLabelFallsBackWhenMissingOrEmpty() {
        XCTAssertEqual(AccountProfileSummary(email: "a", accountRole: "DONOR", zip: nil, city: nil, phone: nil).zipLabel, "Not set")
        XCTAssertEqual(AccountProfileSummary(email: "a", accountRole: "DONOR", zip: "", city: nil, phone: nil).zipLabel, "Not set")
        XCTAssertEqual(AccountProfileSummary(email: "a", accountRole: "DONOR", zip: "78701", city: nil, phone: nil).zipLabel, "78701")
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
