import Foundation
import XCTest
@testable import DADFoundation

final class LegacyAttributionTests: XCTestCase {
    func testAccountDeletionClearsLegacyAttributionWithoutRemovingCurrentTokens() {
        let suite = "legacy-attribution-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("old-attribution".utf8), forKey: "org.dad.attribution")
        let tokens = DefaultsLinkTokenStore(defaults: defaults)
        tokens.save(LinkTokens(referral: "current-referral", company: "current-company"))

        LegacyAttribution.clear(defaults: defaults)
        LegacyAttribution.clear(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: "org.dad.attribution"))
        XCTAssertEqual(tokens.load(), LinkTokens(referral: "current-referral", company: "current-company"))
    }
}

// MARK: - Phone sign-in state machine

final class PhoneSignInModelTests: XCTestCase {
    private actor FakeService: SignInService {
        enum Mode { case ok, badCode, unreachable }
        let mode: Mode
        private(set) var requested: [String] = []
        init(mode: Mode) { self.mode = mode }
        func requestPhoneCode(phone: String) async throws -> String {
            requested.append(phone)
            if mode == .unreachable { throw AccountError.unavailable }
            return "handle-\(phone)"
        }
        func verifyPhone(handle: String, code: String) async throws -> Credentials {
            switch mode {
            case .ok: return Credentials(access: "a", refresh: "r", expiresAt: .distantFuture)
            case .badCode: throw AccountError.signedOut
            case .unreachable: throw AccountError.unavailable
            }
        }
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Credentials?
        func set(_ v: Credentials) { lock.withLock { value = v } }
        var get: Credentials? { lock.withLock { value } }
    }

    @MainActor
    func testHappyPathRequestThenVerifyEstablishes() async {
        let established = Box()
        let model = PhoneSignInModel(service: FakeService(mode: .ok)) { established.set($0) }
        model.phone = "+14155551234"
        XCTAssertTrue(model.canRequestCode)
        await model.requestCode()
        guard case .enterCode(let handle) = model.phase else { return XCTFail("expected enterCode, got \(model.phase)") }
        XCTAssertEqual(handle, "handle-+14155551234")
        model.code = "123456"
        XCTAssertTrue(model.canVerify)
        await model.verify()
        guard case .signedIn = model.phase else { return XCTFail("expected signedIn, got \(model.phase)") }
        XCTAssertNotNil(established.get)
    }

    @MainActor
    func testInvalidPhoneBlocksRequest() async {
        let model = PhoneSignInModel(service: FakeService(mode: .ok)) { _ in }
        model.phone = "5551234"   // no +, too short
        XCTAssertFalse(model.canRequestCode)
        await model.requestCode()
        XCTAssertEqual(model.phase, .enterPhone)  // unchanged
    }

    @MainActor
    func testBadCodeFailsButRetryPreservesHandle() async {
        let model = PhoneSignInModel(service: FakeService(mode: .badCode)) { _ in }
        model.phone = "+14155551234"
        await model.requestCode()
        model.code = "000000"
        await model.verify()
        guard case .failed = model.phase else { return XCTFail("expected failed, got \(model.phase)") }
        XCTAssertTrue(model.isAwaitingCode, "a wrong code keeps the screen on code entry, not back at the phone field")
        model.retryCodeEntry()
        // Retry returns to code entry WITHOUT re-requesting a code (same handle).
        guard case .enterCode(let handle) = model.phase else { return XCTFail("expected enterCode, got \(model.phase)") }
        XCTAssertEqual(handle, "handle-+14155551234")
    }

    @MainActor
    func testUnreachableOnRequestSurfacesFailure() async {
        let model = PhoneSignInModel(service: FakeService(mode: .unreachable)) { _ in }
        model.phone = "+14155551234"
        await model.requestCode()
        guard case .failed = model.phase else { return XCTFail("expected failed, got \(model.phase)") }
        XCTAssertFalse(model.isAwaitingCode, "a failed SMS request has no code to wait for")
        // retry with no handle falls back to the phone screen.
        model.retryCodeEntry()
        XCTAssertEqual(model.phase, .enterPhone)
    }
}
