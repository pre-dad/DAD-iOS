import Foundation
import XCTest
@testable import DADFoundation

private actor FakeSignup: SignupService {
    var forms: [SignupForm] = []
    var failure: Error?
    func setFailure(_ error: Error?) { failure = error }
    func requestSignup(_ form: SignupForm) async throws {
        forms.append(form)
        if let failure { throw failure }
    }
}

private actor FakeSignInLink: SignInLinkService {
    var emails: [String] = []
    var failure: Error?
    func setFailure(_ error: Error?) { failure = error }
    func requestSignInLink(email: String) async throws {
        emails.append(email)
        if let failure { throw failure }
    }
}

private final class FakePasswordSignIn: PasswordSignInService, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [(String, String)] = []
    var result: Result<Credentials, Error> = .success(Credentials(access: "A", refresh: "R", expiresAt: .distantFuture))
    var calls: [(String, String)] { lock.withLock { seen } }
    func signIn(email: String, password: String) async throws -> Credentials {
        lock.withLock { seen.append((email, password)) }
        return try result.get()
    }
}

private final class FakePasswordSettings: PasswordSettingsService, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [(String?, String)] = []
    var failure: Error?
    var calls: [(String?, String)] { lock.withLock { seen } }
    func setPassword(current: String?, new: String) async throws {
        lock.withLock { seen.append((current, new)) }
        if let failure { throw failure }
    }
}

private let establishDirectly: PhoneSignInModel.Establish = { try await $0() }

final class CredentialRulesTests: XCTestCase {
    @MainActor func testEmailRuleMatchesTheSharedPartnerRule() {
        let good = ["a@b.co", "alex.r@mail.example.org", "  padded@example.org  "]
        let bad = ["", "a@b", "a@@b.co", "@b.co", "a@.co", "a@b..co", "a b@c.co", "a@b.co.", String(repeating: "a", count: 250) + "@b.co"]
        for email in good { XCTAssertTrue(CredentialRules.isPlausibleEmail(email), email) }
        for email in bad { XCTAssertFalse(CredentialRules.isPlausibleEmail(email), email) }
        for email in good + bad { XCTAssertEqual(CredentialRules.isPlausibleEmail(email), PartnerModel.isPlausibleEmail(email), email) }
    }

    func testPasswordRulesCountBytesNotCharacters() {
        XCTAssertFalse(CredentialRules.isAcceptableNewPassword(String(repeating: "a", count: 11)))
        XCTAssertTrue(CredentialRules.isAcceptableNewPassword(String(repeating: "a", count: 12)))
        XCTAssertTrue(CredentialRules.isAcceptableNewPassword(String(repeating: "a", count: 72)))
        XCTAssertFalse(CredentialRules.isAcceptableNewPassword(String(repeating: "a", count: 73)))
        // Three four-byte emoji are 12 bytes: acceptable, though only three characters.
        XCTAssertTrue(CredentialRules.isAcceptableNewPassword("😀😀😀"))
        // 19 emoji are 76 bytes: over bcrypt's limit despite being few characters.
        XCTAssertFalse(CredentialRules.isAcceptableNewPassword(String(repeating: "😀", count: 19)))
        XCTAssertFalse(CredentialRules.isSubmittablePassword(""))
        XCTAssertTrue(CredentialRules.isSubmittablePassword("x"))
        XCTAssertFalse(CredentialRules.isSubmittablePassword(String(repeating: "a", count: 73)))
    }

    func testZipRule() {
        for zip in ["78701", " 78701 "] { XCTAssertTrue(CredentialRules.isPlausibleZip(zip), zip) }
        for zip in ["", "7870", "787011", "7870a", "78701-1234"] { XCTAssertFalse(CredentialRules.isPlausibleZip(zip), zip) }
    }
}

@MainActor final class SignupModelTests: XCTestCase {
    private func filled(_ service: FakeSignup) -> SignupModel {
        let model = SignupModel(service: service)
        model.name = "  Alex Rivera "; model.email = " alex@example.org "; model.zip = "78701"; model.city = " Austin "
        return model
    }

    func testCannotSubmitUntilEveryFieldIsValid() {
        let model = SignupModel(service: FakeSignup())
        XCTAssertFalse(model.canSubmit)
        model.name = "Alex"; model.email = "alex@example.org"; model.zip = "78701"
        XCTAssertFalse(model.canSubmit, "city is required")
        model.city = "Austin"
        XCTAssertTrue(model.canSubmit)
        model.zip = "787"
        XCTAssertFalse(model.canSubmit)
        model.zip = "78701"; model.email = "nope"
        XCTAssertFalse(model.canSubmit)
        model.email = "alex@example.org"; model.name = "   "
        XCTAssertFalse(model.canSubmit, "whitespace-only name")
    }

    func testSubmitTrimsSendsOnceAndReportsTheAddress() async {
        let service = FakeSignup()
        let model = filled(service)
        await model.submit()
        XCTAssertEqual(model.phase, .sent(email: "alex@example.org"))
        let forms = await service.forms
        XCTAssertEqual(forms, [SignupForm(name: "Alex Rivera", email: "alex@example.org", zip: "78701", city: "Austin")])
    }

    func testFailureMappingKeepsTheFormAndAllowsRetry() async {
        let cases: [(AccountError, String)] = [
            (.invalidInput, "Check your name"), (.rateLimited, "Too many"), (.unavailable, "couldn’t send"), (.invalidResponse, "Something went wrong"),
        ]
        for (error, fragment) in cases {
            let service = FakeSignup()
            await service.setFailure(error)
            let model = filled(service)
            await model.submit()
            guard case .failed(let message) = model.phase else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains(fragment), "\(error): \(message)")
            XCTAssertEqual(model.email, " alex@example.org ", "form values survive a failure")
            model.edit()
            XCTAssertEqual(model.phase, .editing)
            XCTAssertTrue(model.canSubmit)
        }
    }

    func testCancellationReturnsToEditingWithoutAnError() async {
        let service = FakeSignup()
        await service.setFailure(CancellationError())
        let model = filled(service)
        await model.submit()
        XCTAssertEqual(model.phase, .editing)
    }

    func testInvalidFormNeverCallsTheService() async {
        let service = FakeSignup()
        let model = SignupModel(service: service)
        await model.submit()
        let forms = await service.forms
        XCTAssertTrue(forms.isEmpty)
    }
}

@MainActor final class SignInLinkModelTests: XCTestCase {
    func testSubmitTrimsSendsOnceAndReportsTheAddress() async {
        let service = FakeSignInLink()
        let model = SignInLinkModel(service: service)
        XCTAssertFalse(model.canSubmit)
        model.email = " alex@example.org "
        XCTAssertTrue(model.canSubmit)
        await model.submit()
        XCTAssertEqual(model.phase, .sent(email: "alex@example.org"))
        let emails = await service.emails
        XCTAssertEqual(emails, ["alex@example.org"])
    }

    func testInvalidEmailNeverCallsTheService() async {
        let service = FakeSignInLink()
        let model = SignInLinkModel(service: service)
        model.email = "not an email"
        await model.submit()
        XCTAssertEqual(model.phase, .editing)
        let emails = await service.emails
        XCTAssertTrue(emails.isEmpty)
    }

    func testFailuresKeepTheAddressAndAllowRetry() async {
        let cases: [(Error, String)] = [
            (AccountError.invalidInput, "Check your email"), (AccountError.rateLimited, "Too many"),
            (AccountError.unavailable, "couldn’t send"), (AccountError.invalidResponse, "Something went wrong"),
        ]
        for (error, fragment) in cases {
            let service = FakeSignInLink()
            await service.setFailure(error)
            let model = SignInLinkModel(service: service)
            model.email = "alex@example.org"
            await model.submit()
            guard case .failed(let message) = model.phase else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains(fragment), "\(error): \(message)")
            XCTAssertEqual(model.email, "alex@example.org")
            XCTAssertTrue(model.canSubmit, "a failed request can be retried")
        }
    }

    func testCancellationReturnsToEditingWithoutAnError() async {
        let service = FakeSignInLink()
        await service.setFailure(CancellationError())
        let model = SignInLinkModel(service: service)
        model.email = "alex@example.org"
        await model.submit()
        XCTAssertEqual(model.phase, .editing)
    }
}

@MainActor final class PasswordSignInModelTests: XCTestCase {
    func testSuccessEstablishesAndClearsThePassword() async {
        let service = FakePasswordSignIn()
        let model = PasswordSignInModel(service: service, establish: establishDirectly)
        model.email = " alex@example.org "; model.password = "correct horse"
        XCTAssertTrue(model.canSubmit)
        await model.submit()
        guard case .signedIn = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertEqual(service.calls.first?.0, "alex@example.org")
        XCTAssertEqual(service.calls.first?.1, "correct horse")
        XCTAssertEqual(model.password, "", "the password must not outlive the call")
    }

    func testWrongPasswordFailsClearsTheSecretAndKeepsTheEmail() async {
        let service = FakePasswordSignIn()
        service.result = .failure(AccountError.signedOut)
        let model = PasswordSignInModel(service: service, establish: establishDirectly)
        model.email = "alex@example.org"; model.password = "wrong"
        await model.submit()
        XCTAssertEqual(model.phase, .failed("The email or password is incorrect."))
        XCTAssertEqual(model.password, "")
        XCTAssertEqual(model.email, "alex@example.org")
        XCTAssertFalse(model.canSubmit, "retry needs the password re-entered")
        model.password = "right"
        XCTAssertTrue(model.canSubmit)
    }

    func testStatusMessages() async {
        for (error, fragment) in [(AccountError.rateLimited, "Too many"), (.unavailable, "couldn’t reach"), (.invalidInput, "Check your email")] {
            let service = FakePasswordSignIn()
            service.result = .failure(error)
            let model = PasswordSignInModel(service: service, establish: establishDirectly)
            model.email = "alex@example.org"; model.password = "pw"
            await model.submit()
            guard case .failed(let message) = model.phase else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains(fragment), message)
        }
    }

    func testSubmitIsGatedByInputRules() async {
        let service = FakePasswordSignIn()
        let model = PasswordSignInModel(service: service, establish: establishDirectly)
        model.email = "not-an-email"; model.password = "pw"
        XCTAssertFalse(model.canSubmit)
        await model.submit()
        XCTAssertTrue(service.calls.isEmpty)
        model.email = "alex@example.org"; model.password = String(repeating: "a", count: 73)
        XCTAssertFalse(model.canSubmit)
    }

    func testEstablishThroughTheSessionDiscardsALateResultAfterSignOut() async throws {
        let gate = Gate()
        let transport = ScriptedTransport { _, _ in await gate.pass(); return (.ok, nativeSessionJSON) }
        let session = try AccountSession(api: ControlledAPI(), store: MemoryStore(nil))
        let model = PasswordSignInModel(service: WireCredentialAuth(origin: testOrigin, transport: transport)) { produce in
            try await session.establish(produce)
        }
        model.email = "alex@example.org"; model.password = "pw"
        let task = Task { await model.submit() }
        await gate.waitUntilEntered()
        try await session.discardLocal()
        await gate.release()
        await task.value
        let signedIn = await session.isSignedIn
        XCTAssertFalse(signedIn)
        guard case .failed = model.phase else { return XCTFail("a late result must not read as signed in: \(model.phase)") }
    }
}

@MainActor final class PasswordChangeModelTests: XCTestCase {
    func testRulesGateSave() {
        let model = PasswordChangeModel(service: FakePasswordSettings())
        XCTAssertFalse(model.canSave)
        model.newPassword = "short"
        XCTAssertNotNil(model.newPasswordHint)
        XCTAssertFalse(model.canSave)
        model.newPassword = "a long enough passphrase"
        XCTAssertNil(model.newPasswordHint)
        XCTAssertFalse(model.canSave, "confirmation required")
        model.confirmPassword = "a long enough passphras"
        XCTAssertTrue(model.confirmMismatch)
        XCTAssertFalse(model.canSave)
        model.confirmPassword = "a long enough passphrase"
        XCTAssertTrue(model.canSave)
        model.currentPassword = String(repeating: "a", count: 73)
        XCTAssertFalse(model.canSave)
    }

    func testSaveSendsCurrentOnlyWhenGivenAndClearsEveryField() async {
        let service = FakePasswordSettings()
        let model = PasswordChangeModel(service: service)
        model.newPassword = "a long enough passphrase"; model.confirmPassword = "a long enough passphrase"
        await model.save()
        XCTAssertEqual(model.phase, .saved)
        XCTAssertNil(service.calls[0].0)
        XCTAssertEqual([model.currentPassword, model.newPassword, model.confirmPassword], ["", "", ""])
        model.edit()
        model.currentPassword = "old one here"; model.newPassword = "another long passphrase"; model.confirmPassword = "another long passphrase"
        await model.save()
        XCTAssertEqual(service.calls[1].0, "old one here")
    }

    func testFailureMessagesAndSessionLoss() async {
        let cases: [(AccountError, String, Bool)] = [
            (.passwordIncorrect, "current password didn’t match", false), (.invalidInput, "12 to 72", false),
            (.rateLimited, "Too many", false), (.unavailable, "couldn’t save", false), (.signedOut, "sign in again", true),
        ]
        for (error, fragment, signsOut) in cases {
            let service = FakePasswordSettings()
            service.failure = error
            let model = PasswordChangeModel(service: service)
            model.newPassword = "a long enough passphrase"; model.confirmPassword = "a long enough passphrase"
            await model.save()
            guard case .failed(let message) = model.phase else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains(fragment), "\(error): \(message)")
            XCTAssertEqual(model.signedOut, signsOut, "\(error)")
            XCTAssertEqual(model.newPassword, "a long enough passphrase", "a failed save keeps the form for a retry")
        }
    }
}

final class SignInCapabilityTests: XCTestCase {
    func testEmptyConfigurationLeavesOnlyPhoneAndPasswordOn() {
        let capabilities = SignInCapabilities(config: SignInConfig(appleFlag: "", googleClientID: "", passkeyRelyingParty: ""))
        XCTAssertEqual(capabilities, .none)
        XCTAssertTrue(capabilities.isAvailable(.phone))
        XCTAssertTrue(capabilities.isAvailable(.password))
        for method in [SignInMethod.apple, .google, .passkey] { XCTAssertFalse(capabilities.isAvailable(method), method.rawValue) }
        XCTAssertTrue(capabilities.hasUnavailableMethod)
        XCTAssertEqual(SignInCapabilities(config: SignInConfig(appleFlag: nil, googleClientID: nil, passkeyRelyingParty: nil)), .none)
    }

    func testEachMethodSwitchesOnlyWithItsOwnValidConfiguration() {
        XCTAssertTrue(SignInCapabilities(config: SignInConfig(appleFlag: "YES", googleClientID: nil, passkeyRelyingParty: nil)).apple)
        XCTAssertFalse(SignInCapabilities(config: SignInConfig(appleFlag: "NO", googleClientID: nil, passkeyRelyingParty: nil)).apple)
        let client = "1234-abc.apps.googleusercontent.com"
        XCTAssertFalse(SignInCapabilities(config: SignInConfig(appleFlag: nil, googleClientID: client, passkeyRelyingParty: nil)).google,
                       "a client ID alone cannot switch Google on without a linked provider")
        XCTAssertTrue(SignInCapabilities(config: SignInConfig(appleFlag: nil, googleClientID: client, passkeyRelyingParty: nil),
                                         googleProviderAvailable: true).google)
        XCTAssertFalse(SignInCapabilities(config: SignInConfig(appleFlag: nil, googleClientID: "not-a-client-id", passkeyRelyingParty: nil),
                                          googleProviderAvailable: true).google)
        XCTAssertTrue(SignInCapabilities(config: SignInConfig(appleFlag: nil, googleClientID: nil, passkeyRelyingParty: "dad.example.org")).passkey)
        for junk in ["https://dad.example.org", "dad", "dad.example.org/path", "Dad Example.org", "-bad.example.org"] {
            XCTAssertFalse(SignInCapabilities(config: SignInConfig(appleFlag: nil, googleClientID: nil, passkeyRelyingParty: junk)).passkey, junk)
        }
    }
}

private final class FakeTokens: IDTokenProvider, @unchecked Sendable {
    let result: Result<String, Error>
    private let lock = NSLock()
    private var seen: [OIDCNonce] = []
    var nonces: [OIDCNonce] { lock.withLock { seen } }
    init(result: Result<String, Error>) { self.result = result }
    func idToken(nonce: OIDCNonce) async throws -> String {
        lock.withLock { seen.append(nonce) }
        return try result.get()
    }
}

private struct SequenceNonces: NonceGenerator {
    private let counter = Counter()
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
    }
    func make() -> OIDCNonce { OIDCNonce(raw: "raw-nonce-\(counter.next())") }
}

private final class FakeOIDC: OIDCSignInService, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [(OIDCProvider, String, String)] = []
    var result: Result<Credentials, Error> = .success(Credentials(access: "A", refresh: "R", expiresAt: .distantFuture))
    var calls: [(OIDCProvider, String, String)] { lock.withLock { seen } }
    func signIn(provider: OIDCProvider, idToken: String, nonce: String) async throws -> Credentials {
        lock.withLock { seen.append((provider, idToken, nonce)) }
        return try result.get()
    }
}

@MainActor final class OIDCSignInModelTests: XCTestCase {
    func testSuccessExchangesTheTokenForTheRightProvider() async {
        let service = FakeOIDC()
        let model = OIDCSignInModel(provider: .google, tokens: FakeTokens(result: .success("jwt")), service: service, establish: establishDirectly)
        await model.start()
        guard case .signedIn = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertEqual(service.calls.first?.0, .google)
        XCTAssertEqual(service.calls.first?.1, "jwt")
    }

    func testProviderGetsTheNonceAndTheServerGetsTheRawValue() async throws {
        let service = FakeOIDC(), tokens = FakeTokens(result: .success("jwt"))
        let model = OIDCSignInModel(provider: .apple, tokens: tokens, service: service, nonces: SequenceNonces(), establish: establishDirectly)
        await model.start()
        let bound = try XCTUnwrap(tokens.nonces.first)
        XCTAssertEqual(bound.raw, "raw-nonce-1")
        XCTAssertEqual(service.calls.first?.2, "raw-nonce-1")
        XCTAssertEqual(bound.hashed, OIDCNonce(raw: "raw-nonce-1").hashed)
        XCTAssertNotEqual(bound.hashed, bound.raw)
    }

    func testEveryAttemptIncludingARetryAfterFailureDrawsAFreshNonce() async {
        let service = FakeOIDC(), tokens = FakeTokens(result: .success("jwt"))
        service.result = .failure(AccountError.unavailable)
        let model = OIDCSignInModel(provider: .apple, tokens: tokens, service: service, nonces: SequenceNonces(), establish: establishDirectly)
        await model.start()
        await model.start()
        XCTAssertEqual(tokens.nonces.map(\.raw), ["raw-nonce-1", "raw-nonce-2"])
        XCTAssertEqual(service.calls.map(\.2), ["raw-nonce-1", "raw-nonce-2"])
    }

    func testCancellingThePlatformSheetIsQuietNotAnError() async {
        let service = FakeOIDC()
        for error in [ExternalSignInError.cancelled as Error, CancellationError()] {
            let model = OIDCSignInModel(provider: .apple, tokens: FakeTokens(result: .failure(error)), service: service, establish: establishDirectly)
            await model.start()
            XCTAssertEqual(model.phase, .idle)
        }
        XCTAssertTrue(service.calls.isEmpty)
    }

    func testCancellationLeavesNoNonceSentToTheServerAndRetryDrawsANewOne() async {
        let service = FakeOIDC()
        let cancelled = FakeTokens(result: .failure(ExternalSignInError.cancelled))
        let model = OIDCSignInModel(provider: .apple, tokens: cancelled, service: service, nonces: SequenceNonces(), establish: establishDirectly)
        await model.start()
        await model.start()
        XCTAssertEqual(cancelled.nonces.map(\.raw), ["raw-nonce-1", "raw-nonce-2"])
        XCTAssertTrue(service.calls.isEmpty)
    }

    func testFailureMessages() async {
        let cases: [(Error, String)] = [
            (AccountError.signedOut, "couldn’t find a DAD account for that Apple"), (AccountError.rateLimited, "Too many"),
            (AccountError.unavailable, "Apple sign-in isn’t available right now"), (ExternalSignInError.unsupported, "isn’t available on this device"),
            (AccountError.invalidResponse, "Something went wrong"),
        ]
        for (error, fragment) in cases {
            let service = FakeOIDC()
            service.result = .failure(error)
            let model = OIDCSignInModel(provider: .apple, tokens: FakeTokens(result: .success("jwt")), service: service, establish: establishDirectly)
            await model.start()
            guard case .failed(let message) = model.phase else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains(fragment), "\(error): \(message)")
        }
    }
}

private struct FakeAuthenticator: PasskeyAuthenticator {
    let result: Result<PasskeyAssertion, Error>
    func assertion(for challenge: PasskeyChallenge) async throws -> PasskeyAssertion { try result.get() }
}

private let modelOptionsJSON = #"{"ceremony":"\#(String(repeating: "c", count: 40))","options":{"challenge":"AAECAwQ"}}"#

@MainActor final class PasskeySignInModelTests: XCTestCase {
    private let assertion = PasskeyAssertion(credentialID: Data([1]), clientDataJSON: Data([2]), authenticatorData: Data([3]),
                                             signature: Data([4]), userHandle: nil)

    func testFullFlowThroughWireAndSession() async throws {
        let transport = ScriptedTransport { seen, _ in (seen.request.path ?? "").hasSuffix("/options") ? (.ok, modelOptionsJSON) : (.ok, nativeSessionJSON) }
        let session = try AccountSession(api: ControlledAPI(), store: MemoryStore(nil))
        let model = PasskeySignInModel(authenticator: FakeAuthenticator(result: .success(assertion)),
                                       service: WireCredentialAuth(origin: testOrigin, transport: transport)) { try await session.establish($0) }
        await model.start()
        guard case .signedIn = model.phase else { return XCTFail("\(model.phase)") }
        let signedIn = await session.isSignedIn
        XCTAssertTrue(signedIn)
        XCTAssertEqual(transport.seen.map { $0.request.path ?? "" }, ["/donor/passkeys/sign-in/options", "/donor/passkeys/sign-in"])
    }

    func testCancelledCeremonyStopsBeforeFinishAndIsQuiet() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, modelOptionsJSON) }
        let model = PasskeySignInModel(authenticator: FakeAuthenticator(result: .failure(ExternalSignInError.cancelled)),
                                       service: WireCredentialAuth(origin: testOrigin, transport: transport), establish: establishDirectly)
        await model.start()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(transport.seen.count, 1, "finish must not be called without an assertion")
    }

    func testServerRejectionAndOutageMessages() async {
        for (status, fragment) in [(HTTPStatusBox(401), "didn’t work"), (HTTPStatusBox(429), "Too many"), (HTTPStatusBox(503), "isn’t available right now")] {
            let transport = ScriptedTransport { seen, _ in
                (seen.request.path ?? "").hasSuffix("/options") ? (.ok, modelOptionsJSON) : (status.status, "{}")
            }
            let model = PasskeySignInModel(authenticator: FakeAuthenticator(result: .success(assertion)),
                                           service: WireCredentialAuth(origin: testOrigin, transport: transport), establish: establishDirectly)
            await model.start()
            guard case .failed(let message) = model.phase else { return XCTFail("\(status.code)") }
            XCTAssertTrue(message.contains(fragment), message)
        }
    }

    func testUnsupportedDevice() async {
        let transport = ScriptedTransport { _, _ in (.ok, modelOptionsJSON) }
        let model = PasskeySignInModel(authenticator: FakeAuthenticator(result: .failure(ExternalSignInError.unsupported)),
                                       service: WireCredentialAuth(origin: testOrigin, transport: transport), establish: establishDirectly)
        await model.start()
        XCTAssertEqual(model.phase, .failed("Passkeys aren’t available on this device."))
    }
}

import HTTPTypes

private struct HTTPStatusBox {
    let status: HTTPResponse.Status
    var code: Int { status.code }
    init(_ code: Int) { status = HTTPResponse.Status(code: code) }
}
