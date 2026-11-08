import AuthenticationServices
import DADFoundation
import UIKit

// Platform ceremonies behind the library seams: Sign in with Apple (id_token) and passkey
// assertions. Neither runs unless `SignInCapabilities` switched the method on, which needs build
// configuration the repository does not contain (see README, "Switching on Apple, Google and
// passkeys"). Nothing here logs a token, assertion or credential.

/// Runs one AuthenticationServices request at a time and resumes with its result.
@MainActor
private final class AuthorizationRun: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<ASAuthorization, Error>?
    private var controller: ASAuthorizationController?

    func perform(_ requests: [ASAuthorizationRequest]) async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: requests)
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<ASAuthorization, Error>) {
        continuation?.resume(with: result)
        continuation = nil
        controller = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        finish(.success(authorization))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        // The person dismissing the sheet is not a failure; anything else is surfaced as-is
        // and mapped to a generic user message by the model.
        if let failure = error as? ASAuthorizationError, failure.code == .canceled {
            finish(.failure(ExternalSignInError.cancelled))
        } else if let failure = error as? ASAuthorizationError, failure.code == .notHandled || failure.code == .notInteractive {
            finish(.failure(ExternalSignInError.unsupported))
        } else {
            finish(.failure(error))
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

/// Sign in with Apple. Requires the "Sign in with Apple" capability (entitlement
/// `com.apple.developer.applesignin`) on a signed build; without it the request fails and the
/// model reports the method as unavailable on this device.
struct AppleIDTokenProvider: IDTokenProvider {
    func idToken(nonce: OIDCNonce) async throws -> String {
        try await appleIDToken(nonce: nonce)
    }
}

@MainActor private func appleIDToken(nonce: OIDCNonce) async throws -> String {
    let run = AuthorizationRun()
    return try await run.fetch(nonce: nonce)
}

@MainActor private func passkeyAssertion(relyingParty: String, challenge: Data) async throws -> PasskeyAssertion {
    let run = AuthorizationRun()
    return try await run.assert(relyingParty: relyingParty, challenge: challenge)
}

private extension AuthorizationRun {
    func fetch(nonce: OIDCNonce) async throws -> String {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.email]
        request.nonce = nonce.hashed
        let authorization = try await perform([request])
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = credential.identityToken, let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw AccountError.invalidResponse
        }
        return token
    }
}

/// Passkey assertion for the donor's relying party. Requires the Associated Domains entitlement
/// `webcredentials:<relying party>` and an apple-app-site-association file served by that domain.
struct PlatformPasskeyAuthenticator: PasskeyAuthenticator {
    /// Used when the server's options carry no `rpId`.
    let fallbackRelyingParty: String

    func assertion(for challenge: PasskeyChallenge) async throws -> PasskeyAssertion {
        let relyingParty = challenge.relyingParty ?? fallbackRelyingParty
        return try await passkeyAssertion(relyingParty: relyingParty, challenge: challenge.challenge)
    }
}

private extension AuthorizationRun {
    func assert(relyingParty: String, challenge: Data) async throws -> PasskeyAssertion {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingParty)
        let authorization = try await perform([provider.createCredentialAssertionRequest(challenge: challenge)])
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw AccountError.invalidResponse
        }
        return PasskeyAssertion(
            credentialID: credential.credentialID, clientDataJSON: credential.rawClientDataJSON,
            authenticatorData: credential.rawAuthenticatorData, signature: credential.signature,
            userHandle: credential.userID.isEmpty ? nil : credential.userID)
    }
}

/// The Google id_token provider, or nil while none is linked into this build (the official SDK is a new
/// dependency the project has not adopted). Google sign-in is offered only when this returns a provider,
/// so linking one here switches the button on once the client id is configured.
enum GoogleSignIn {
    static var provider: (any IDTokenProvider)? { nil }
}
