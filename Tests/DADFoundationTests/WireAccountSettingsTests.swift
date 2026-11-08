import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest
@testable import DADFoundation

final class WireAccountSettingsTests: XCTestCase {
    private typealias Rig = (settings: WireAccountSettings, session: AccountSession, store: MemoryStore, wiped: WipeBox)

    private func make(_ transport: ScriptedTransport) throws -> Rig {
        let store = MemoryStore(Credentials(access: "tok", refresh: "ref", expiresAt: .distantFuture))
        let wiped = WipeBox()
        let session = try AccountSession(api: WireAPI(origin: testOrigin, transport: transport), store: store)
        let product = ProductClient(origin: testOrigin, transport: transport, session: session)
        return (WireAccountSettings(product: product, onLocalWipe: { wiped.hit() }), session, store, wiped)
    }

    func testLoadMapsProfileAndPreferencesWithBearer() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, profileJSON()) }
        let rig = try make(transport)
        let snapshot = try await rig.settings.load()
        XCTAssertEqual(snapshot.profile.email, "alex@example.org")
        XCTAssertEqual(snapshot.profile.accountRole, "DONOR")
        XCTAssertEqual(snapshot.profile.zip, "78701")
        XCTAssertEqual(snapshot.preferences.version, 3)
        XCTAssertFalse(snapshot.preferences.pushEventNearby)
        XCTAssertEqual(transport.seen.first?.request.headerFields[.authorization], "Bearer tok")
    }

    func testSavePreferencesSendsTheReadVersionAndToggles() async throws {
        let transport = ScriptedTransport { seen, _ in (.ok, profileJSON(version: seen.request.method == .post ? 4 : 3)) }
        let rig = try make(transport)
        let current = try await rig.settings.load().preferences
        let saved = try await rig.settings.savePreferences(current.with("push_streak_at_risk", false))
        XCTAssertEqual(saved.preferences.version, 4)
        let post = try XCTUnwrap(transport.calls(to: "/donor/me/preferences").first)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(post.body.utf8)) as? [String: Any])
        XCTAssertEqual(sent["version"] as? Int, 3)
        XCTAssertEqual(sent["push_streak_at_risk"] as? Bool, false)
        XCTAssertEqual(sent["push_event_nearby"] as? Bool, false)
        XCTAssertEqual(sent["rankings_opted_out"] as? Bool, false)
    }

    func testInterestsAreReadAndSentOnlyOnceEdited() async throws {
        let withInterests = profileJSON().replacingOccurrences(of: #""volunteer_interests":[]"#, with: #""volunteer_interests":["Food drives","Tutoring"]"#)
        let transport = ScriptedTransport { _, _ in (.ok, withInterests) }
        let rig = try make(transport)
        let current = try await rig.settings.load().preferences
        XCTAssertEqual(current.volunteerInterests, ["Food drives", "Tutoring"])

        _ = try await rig.settings.savePreferences(current.with("marketing_emails", true))
        let untouched = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(transport.calls(to: "/donor/me/preferences").first).body.utf8)) as? [String: Any])
        XCTAssertNil(untouched["volunteer_interests"], "untouched interests are omitted so the server keeps them")

        let edited = try current.addingInterest("Mentoring").get()
        _ = try await rig.settings.savePreferences(edited)
        let sentBody = try XCTUnwrap(transport.calls(to: "/donor/me/preferences").last).body
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(sentBody.utf8)) as? [String: Any])
        XCTAssertEqual(sent["volunteer_interests"] as? [String], ["Food drives", "Tutoring", "Mentoring"])
    }

    func testStaleInterestSaveSurfacesAsRetryableAndKeepsNothingLocal() async throws {
        let transport = ScriptedTransport { seen, _ in seen.request.method == .post ? (.conflict, "{}") : (.ok, profileJSON()) }
        let rig = try make(transport)
        let current = try await rig.settings.load().preferences
        do { _ = try await rig.settings.savePreferences(try current.addingInterest("Tutoring").get()); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .unavailable) }
    }

    func testDeleteWipesCredentialsAndLocalDataWithoutALogoutCall() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, #"{"deleted":true}"#) }
        let rig = try make(transport)
        try await rig.settings.deleteAccount()
        XCTAssertEqual(transport.calls(to: "/donor/me/delete").count, 1)
        XCTAssertEqual(transport.calls(to: "/donor/me/delete").first?.request.headerFields[.authorization], "Bearer tok")
        XCTAssertNil(try rig.store.load(), "Keychain credentials must be gone after deletion")
        XCTAssertEqual(rig.wiped.count, 1, "local data wipe hook must run")
        let signedIn = await rig.session.isSignedIn
        XCTAssertFalse(signedIn)
        try await rig.settings.signOut()   // the model's follow-up is a harmless no-op
        XCTAssertTrue(transport.calls(to: "/donor/logout").isEmpty, "a deleted account has no session left to revoke")
    }

    func testDeleteBlockedBy409KeepsTheSessionAndExplains() async throws {
        let transport = ScriptedTransport { _, _ in (.conflict, "{}") }
        let rig = try make(transport)
        do { try await rig.settings.deleteAccount(); XCTFail() }
        catch {
            XCTAssertEqual(error as? AccountError, .deletionBlocked)
            XCTAssertTrue(error.userMessage.contains("Cancel your monthly gift"))
        }
        XCTAssertNotNil(try rig.store.load())
        XCTAssertEqual(rig.wiped.count, 0)
        let signedIn = await rig.session.isSignedIn
        XCTAssertTrue(signedIn)
    }

    func testDeleteFailuresNeverWipe() async throws {
        let cases: [(HTTPResponse.Status, AccountError)] = [(.tooManyRequests, .rateLimited), (.serviceUnavailable, .unavailable), (.forbidden, .unavailable)]
        for (status, expected) in cases {
            let rig = try make(ScriptedTransport { _, _ in (status, "{}") })
            do { try await rig.settings.deleteAccount(); XCTFail("\(status)") }
            catch { XCTAssertEqual(error as? AccountError, expected, "\(status)") }
            XCTAssertNotNil(try rig.store.load(), "\(status)")
            XCTAssertEqual(rig.wiped.count, 0, "\(status)")
        }
    }

    func testDelete401RefreshesAndRetriesOnceThenDeletes() async throws {
        let transport = ScriptedTransport { seen, _ in
            switch seen.request.path {
            case "/donor/refresh": return (.ok, freshSessionJSON)
            case "/donor/me/delete":
                return seen.request.headerFields[.authorization] == "Bearer fresh" ? (.ok, #"{"deleted":true}"#) : (.unauthorized, "{}")
            default: return (.notFound, "{}")
            }
        }
        let rig = try make(transport)
        try await rig.settings.deleteAccount()
        XCTAssertEqual(transport.calls(to: "/donor/refresh").count, 1)
        XCTAssertEqual(transport.calls(to: "/donor/me/delete").count, 2)
        XCTAssertNil(try rig.store.load())
        XCTAssertEqual(rig.wiped.count, 1)
    }

    func testDeleteWhenRefreshIsRevokedEndsSignedOutWithoutWipingAppData() async throws {
        let rig = try make(ScriptedTransport { _, _ in (.unauthorized, "{}") })
        do { try await rig.settings.deleteAccount(); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .signedOut) }
        XCTAssertNil(try rig.store.load())
        XCTAssertEqual(rig.wiped.count, 0, "nothing was deleted server-side")
    }

    func testConcurrentDeletesShareOneRefresh() async throws {
        let transport = ScriptedTransport { seen, _ in
            if seen.request.path == "/donor/refresh" { return (.ok, freshSessionJSON) }
            return seen.request.headerFields[.authorization] == "Bearer fresh" ? (.ok, #"{"deleted":true}"#) : (.unauthorized, "{}")
        }
        let rig = try make(transport)
        let settings = rig.settings
        let first = Task { try await settings.deleteAccount() }
        let second = Task { try await settings.deleteAccount() }
        let results = [await first.result, await second.result]
        XCTAssertTrue(results.contains { if case .success = $0 { true } else { false } })
        XCTAssertEqual(transport.calls(to: "/donor/refresh").count, 1, "refresh is single-flight")
    }

    func testSignOutClearsLocalFirstAndToleratesRemoteFailure() async throws {
        let transport = ScriptedTransport { _, _ in (.serviceUnavailable, "{}") }
        let rig = try make(transport)
        try await rig.settings.signOut()
        XCTAssertNil(try rig.store.load())
        let signedIn = await rig.session.isSignedIn
        XCTAssertFalse(signedIn)
        XCTAssertEqual(transport.calls(to: "/donor/logout").count, 1)
        XCTAssertEqual(transport.calls(to: "/donor/logout").first?.request.headerFields[.authorization], "Bearer tok")
    }

    func testCancelledLoadThrowsCancellation() async throws {
        let gate = Gate()
        let rig = try make(ScriptedTransport { _, _ in await gate.pass(); return (.ok, profileJSON()) })
        let settings = rig.settings
        let task = Task { try await settings.load() }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail("cancelled caller received a result") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    }

    @MainActor func testModelDeleteLeavesShellWhenServerConfirms() async throws {
        let rig = try make(ScriptedTransport { seen, _ in
            seen.request.path == "/donor/me/delete" ? (.ok, #"{"deleted":true}"#) : (.ok, profileJSON())
        })
        let model = AccountSettingsModel(service: rig.settings)
        await model.load()
        await model.deleteAccount(DeleteAccountGate(typed: "DELETE"))
        XCTAssertTrue(model.signedOut)
        XCTAssertNil(try rig.store.load())
    }

    @MainActor func testModelBlockedDeleteStaysInShellWithExplanation() async throws {
        let rig = try make(ScriptedTransport { seen, _ in
            seen.request.path == "/donor/me/delete" ? (.conflict, "{}") : (.ok, profileJSON())
        })
        let model = AccountSettingsModel(service: rig.settings)
        await model.load()
        await model.deleteAccount(DeleteAccountGate(typed: "DELETE"))
        XCTAssertFalse(model.signedOut)
        XCTAssertTrue(model.actionError?.contains("Cancel your monthly gift") == true)
        XCTAssertNotNil(try rig.store.load())
    }
}
