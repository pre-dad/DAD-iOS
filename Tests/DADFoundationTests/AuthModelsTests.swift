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
        enum Mode { case ok, badCode, unreachable, cancelled, signedOutOnRequest }
        let mode: Mode
        private(set) var requested: [String] = []
        init(mode: Mode) { self.mode = mode }
        func requestPhoneCode(phone: String) async throws -> String {
            requested.append(phone)
            switch mode {
            case .unreachable: throw AccountError.unavailable
            case .cancelled: throw CancellationError()
            case .signedOutOnRequest: throw AccountError.signedOut
            default: return "handle-\(phone)"
            }
        }
        func verifyPhone(handle: String, code: String) async throws -> Credentials {
            switch mode {
            case .ok, .signedOutOnRequest: return Credentials(access: "a", refresh: "r", expiresAt: .distantFuture)
            case .badCode: throw AccountError.signedOut
            case .unreachable: throw AccountError.unavailable
            case .cancelled: throw CancellationError()
            }
        }
    }

    private static func establishRecording(_ box: Box) -> PhoneSignInModel.Establish {
        { produce in
            let credentials = try await produce()
            box.set(credentials)
            return credentials
        }
    }

    private static let establishDirectly: PhoneSignInModel.Establish = { try await $0() }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Credentials?
        func set(_ v: Credentials) { lock.withLock { value = v } }
        var get: Credentials? { lock.withLock { value } }
    }

    @MainActor
    func testHappyPathRequestThenVerifyEstablishes() async {
        let established = Box()
        let model = PhoneSignInModel(service: FakeService(mode: .ok), establish: Self.establishRecording(established))
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
        let model = PhoneSignInModel(service: FakeService(mode: .ok), establish: Self.establishDirectly)
        model.phone = "5551234"   // no +, too short
        XCTAssertFalse(model.canRequestCode)
        await model.requestCode()
        XCTAssertEqual(model.phase, .enterPhone)  // unchanged
    }

    @MainActor
    func testBadCodeFailsAndTheNextAttemptReusesTheHandle() async {
        let service = FakeService(mode: .badCode)
        let model = PhoneSignInModel(service: service, establish: Self.establishDirectly)
        model.phone = "+14155551234"
        await model.requestCode()
        model.code = "000000"
        await model.verify()
        guard case .failed(let message) = model.phase else { return XCTFail("expected failed, got \(model.phase)") }
        XCTAssertEqual(message, "That code didn’t match. Check it and try again.")
        XCTAssertTrue(model.isAwaitingCode, "a wrong code keeps the screen on code entry, not back at the phone field")
        model.code = "111111"
        await model.verify()
        let requested = await service.requested
        XCTAssertEqual(requested, ["+14155551234"], "retrying the code must not request a fresh SMS")
        XCTAssertTrue(model.isAwaitingCode)
    }

    @MainActor
    func testTypedUSNumbersAreNormalisedToE164BeforeSending() async {
        for typed in ["(555) 123-4567", "5551234567", "1 555 123 4567", "+1 555-123-4567"] {
            let service = FakeService(mode: .ok)
            let model = PhoneSignInModel(service: service, establish: Self.establishDirectly)
            model.phone = typed
            XCTAssertEqual(model.normalizedPhone, "+15551234567", typed)
            XCTAssertTrue(model.canRequestCode, typed)
            XCTAssertNil(model.phoneFormatHint, typed)
            await model.requestCode()
            let requested = await service.requested
            XCTAssertEqual(requested, ["+15551234567"], typed)
        }
    }

    @MainActor
    func testUnsendableNumbersExplainThemselves() {
        let model = PhoneSignInModel(service: FakeService(mode: .ok), establish: Self.establishDirectly)
        XCTAssertNil(model.phoneFormatHint, "an empty field shows no hint")
        for typed in ["5551234", "555-CALL-NOW", "+1234", "+0123456789"] {
            model.phone = typed
            XCTAssertFalse(model.canRequestCode, typed)
            XCTAssertNotNil(model.phoneFormatHint, typed)
        }
    }

    @MainActor
    func testRequestFailuresAreNotReportedAsAWrongCode() async {
        let model = PhoneSignInModel(service: FakeService(mode: .signedOutOnRequest), establish: Self.establishDirectly)
        model.phone = "+14155551234"
        await model.requestCode()
        XCTAssertEqual(model.phase, .failed("Something went wrong. Please try again."))
    }

    @MainActor
    func testCancellationRestoresThePriorScreenInsteadOfFailing() async {
        let model = PhoneSignInModel(service: FakeService(mode: .cancelled), establish: Self.establishDirectly)
        model.phone = "+14155551234"
        await model.requestCode()
        XCTAssertEqual(model.phase, .enterPhone)
    }

    @MainActor
    func testUnreachableOnRequestSurfacesFailure() async {
        let model = PhoneSignInModel(service: FakeService(mode: .unreachable), establish: Self.establishDirectly)
        model.phone = "+14155551234"
        await model.requestCode()
        guard case .failed = model.phase else { return XCTFail("expected failed, got \(model.phase)") }
        XCTAssertFalse(model.isAwaitingCode, "a failed SMS request has no code to wait for")
    }
}
