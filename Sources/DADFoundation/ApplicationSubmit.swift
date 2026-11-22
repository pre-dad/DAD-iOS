import Foundation
import HTTPTypes
import OpenAPIRuntime
import Security

// Native partner application (contract 2.11, `applyWithReceipt`). The app chooses the status receipt, keeps it
// in the Keychain before the request leaves, and later reads `applicationStatus` with it as the bearer. The
// server never echoes the receipt, so losing it before the request is sent would orphan the application.

/// The organization types the website offers. The server stores the value as free text (80 characters).
public enum PartnerOrganizationType: String, CaseIterable, Sendable, Identifiable {
    case corporate = "Corporate", nonprofit = "Nonprofit", foundation = "Foundation", government = "Government", other = "Other"
    public var id: String { rawValue }
}

public struct PartnerApplication: Sendable, Equatable {
    public var organization: String
    public var website: String
    public var type: PartnerOrganizationType
    public var contactName: String
    public var title: String
    public var workEmail: String
    public var phone: String
    public var workforceSize: Int

    public init(organization: String, website: String, type: PartnerOrganizationType, contactName: String, title: String,
                workEmail: String, phone: String, workforceSize: Int) {
        self.organization = organization; self.website = website; self.type = type; self.contactName = contactName
        self.title = title; self.workEmail = workEmail; self.phone = phone; self.workforceSize = workforceSize
    }
}

/// One submission frozen with its idempotency key and receipt, so a retry after an unconfirmed attempt repeats
/// exactly what the server may already have received.
public struct PartnerApplicationAttempt: Sendable, Equatable {
    public let application: PartnerApplication
    public let idempotencyKey: String
    public let receipt: String

    public init(application: PartnerApplication, idempotencyKey: String, receipt: String) {
        self.application = application; self.idempotencyKey = idempotencyKey; self.receipt = receipt
    }

    public static func make(_ application: PartnerApplication) -> PartnerApplicationAttempt {
        PartnerApplicationAttempt(application: application, idempotencyKey: UUID().uuidString.lowercased(), receipt: makeApplicationReceipt())
    }
}

/// 32 random bytes as 43 unpadded base64url characters, the shape the contract requires.
public func makeApplicationReceipt() -> String { SecureNonceGenerator().make().raw }

public enum ApplicationSubmitError: Error, Sendable, Equatable {
    /// 422: a field is invalid, or this work email already has an application under review.
    case invalid
    /// 409: the key was reused with different content.
    case conflict
    /// 403: the request was refused as not coming from the app.
    case forbidden
    /// 429: wait `retryAfter` seconds when the server said how long.
    case rateLimited(retryAfter: Int?)
    /// Any other server status.
    case unavailable
}

public protocol PartnerApplicationService: Sendable {
    /// Keeps the attempt's receipt, then sends it. A definitive refusal forgets the receipt again; a throttle,
    /// an outage or a lost connection keeps it, because the server may have recorded the application.
    func submit(_ attempt: PartnerApplicationAttempt) async throws
}

public struct WirePartnerApplication: PartnerApplicationService {
    private let origin: URL
    private let transport: any ClientTransport
    private let receipt: any CredentialStore
    private let now: @Sendable () -> Date

    /// The server remembers a receipt for 30 days.
    static let receiptLifetime: TimeInterval = 30 * 24 * 60 * 60

    public init(origin: URL, receipt: any CredentialStore) throws {
        guard origin.isBareHTTPSOrigin else { throw AccountError.invalidConfiguration }
        self.init(origin: origin, transport: makeNativeTransport(), receipt: receipt)
    }

    init(origin: URL, transport: any ClientTransport, receipt: any CredentialStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.origin = origin; self.transport = transport; self.receipt = receipt; self.now = now
    }

    public func submit(_ attempt: PartnerApplicationAttempt) async throws {
        try receipt.save(Credentials(access: attempt.receipt, refresh: "", expiresAt: now().addingTimeInterval(Self.receiptLifetime)))
        do {
            try await send(attempt)
        } catch let error as ApplicationSubmitError {
            switch error {
            case .invalid, .conflict, .forbidden: try receipt.clear()
            case .rateLimited, .unavailable: break
            }
            throw error
        }
    }

    private func send(_ attempt: PartnerApplicationAttempt) async throws {
        let client = Client(serverURL: origin, transport: transport, middlewares: [NativeHeaders(access: { nil })])
        let application = attempt.application
        let body = Operations.applyWithReceipt.Input.Body.jsonPayload(
            application: .init(organization: application.organization, website: application.website, _type: application.type.rawValue,
                               contact_name: application.contactName, title: application.title, work_email: application.workEmail,
                               phone: application.phone, workforce_size: application.workforceSize),
            receipt: attempt.receipt)
        do {
            switch try await client.applyWithReceipt(.init(headers: .init(Idempotency_hyphen_Key: attempt.idempotencyKey), body: .json(body))) {
            case .ok: return
            case .forbidden: throw ApplicationSubmitError.forbidden
            case .conflict: throw ApplicationSubmitError.conflict
            case .unprocessableContent: throw ApplicationSubmitError.invalid
            case .tooManyRequests(let response): throw ApplicationSubmitError.rateLimited(retryAfter: response.headers.Retry_hyphen_After)
            case .undocumented(let status, _): throw Self.error(forStatus: status, retryAfter: nil)
            default: throw ApplicationSubmitError.unavailable
            }
        } catch let error as ClientError {
            // An older edge answers 429 with no JSON body: the generated client cannot decode it, but the status
            // and Retry-After are still there.
            if let response = error.response, response.status.code >= 400, !error.underlyingError.isCancellation {
                let seconds = response.headerFields[.retryAfter].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                throw Self.error(forStatus: response.status.code, retryAfter: seconds)
            }
            throw error
        }
    }

    private static func error(forStatus status: Int, retryAfter: Int?) -> ApplicationSubmitError {
        switch status {
        case 403: return .forbidden
        case 409: return .conflict
        case 422: return .invalid
        case 429: return .rateLimited(retryAfter: retryAfter.flatMap { $0 > 0 ? $0 : nil })
        default: return .unavailable
        }
    }
}

@MainActor
@Observable
public final class PartnerApplicationModel {
    public enum Phase: Sendable, Equatable { case editing, submitting, submitted, failed(String) }

    public var organization = ""
    public var website = ""
    public var type = PartnerOrganizationType.corporate
    public var contactName = ""
    public var title = ""
    public var workEmail = ""
    public var phone = ""
    public var workforce = ""

    public private(set) var phase: Phase = .editing
    /// An attempt the server may have received: the form stays as sent and a retry repeats it exactly.
    public private(set) var frozen: PartnerApplicationAttempt?
    private let service: any PartnerApplicationService
    private let makeAttempt: @Sendable (PartnerApplication) -> PartnerApplicationAttempt

    public init(service: any PartnerApplicationService,
                makeAttempt: @escaping @Sendable (PartnerApplication) -> PartnerApplicationAttempt = PartnerApplicationAttempt.make) {
        self.service = service; self.makeAttempt = makeAttempt
    }

    public var isLocked: Bool { frozen != nil }

    /// The form as the server expects it, or nil while a required field is missing or malformed.
    public var application: PartnerApplication? {
        let organization = organization.trimmingCharacters(in: .whitespacesAndNewlines)
        let contact = contactName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = workEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !organization.isEmpty, organization.count <= 200, !contact.isEmpty, contact.count <= 100,
              !title.isEmpty, title.count <= 100, !phone.isEmpty, phone.count <= 40,
              CredentialRules.isPlausibleEmail(email), email.count <= 320,
              let site = Self.normalizedWebsite(website), let size = Int(workforce.trimmingCharacters(in: .whitespaces)), size >= 0
        else { return nil }
        return PartnerApplication(organization: organization, website: site, type: type, contactName: contact, title: title,
                                  workEmail: email, phone: phone, workforceSize: size)
    }

    public var canSubmit: Bool { phase != .submitting && (frozen != nil || application != nil) }

    /// The server takes only https addresses; a bare host gets the scheme the website's form adds.
    static func normalizedWebsite(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 500, !text.contains(" ") else { return nil }
        let full = text.contains("://") ? text : "https://" + text
        guard let components = URLComponents(string: full), components.scheme?.lowercased() == "https",
              components.user == nil, let host = components.host, host.contains(".") else { return nil }
        return full
    }

    public func submit() async {
        guard canSubmit, phase != .submitted else { return }
        let attempt: PartnerApplicationAttempt
        if let frozen { attempt = frozen }
        else if let application { attempt = makeAttempt(application) }
        else { return }
        frozen = attempt
        phase = .submitting
        do {
            try await service.submit(attempt)
            frozen = nil
            phase = .submitted
        } catch where error.isCancellation {
            phase = .editing
        } catch let error as ApplicationSubmitError {
            switch error {
            case .invalid:
                frozen = nil
                phase = .failed("We couldn’t accept that application. Check each field. If this work email already has an application under review, wait for that decision.")
            case .conflict:
                frozen = nil
                phase = .failed("That application changed while it was being sent. Review it and submit again.")
            case .forbidden:
                frozen = nil
                phase = .failed("This build can’t send an application. Apply on the website instead.")
            case .rateLimited(let seconds):
                phase = .failed(Self.waitMessage(seconds))
            case .unavailable:
                phase = .failed(Self.unconfirmed)
            }
        } catch {
            phase = .failed(Self.unconfirmed)
        }
    }

    private static let unconfirmed = "We couldn’t confirm your application was received. Check your connection and retry; nothing will be sent twice."

    static func waitMessage(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return AccountError.rateLimited.userMessage }
        let wait = seconds < 60 ? "\(seconds) second\(seconds == 1 ? "" : "s")" : "\((seconds + 59) / 60) minute\((seconds + 59) / 60 == 1 ? "" : "s")"
        return "Too many attempts. Please wait \(wait) and try again."
    }
}
