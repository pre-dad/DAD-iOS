import Foundation
import HTTPTypes
import OpenAPIRuntime

// Partner application status (PRD P-1..P-3): an organization that applied sees where its application stands
// before it has a portal. The server identifies the application by a private receipt the applicant generated
// when applying; a native request presents that receipt as its bearer (`applicationStatus`).
//
// The app creates that receipt itself by submitting the application natively (`ApplicationSubmit.swift`);
// this file reads the status back with it and forgets it once it is decided.

/// Where an application stands. A status this build does not know is kept verbatim, never guessed.
public enum ApplicationState: Sendable, Equatable {
    case pending, approved, rejected
    case other(String)

    public init(contract raw: String) {
        switch raw {
        case "PENDING": self = .pending
        case "APPROVED": self = .approved
        case "REJECTED": self = .rejected
        default: self = .other(raw)
        }
    }
}

public struct ApplicationStatusInfo: Sendable, Equatable {
    public let organization: String
    public let state: ApplicationState
    public init(organization: String, state: ApplicationState) {
        self.organization = organization
        self.state = state
    }

    /// One sentence for the applicant. No contact details or staff notes ever reach the app.
    public var message: String {
        switch state {
        case .pending: return "Your application for \(organization) is being reviewed. We’ll email you when it’s decided."
        case .approved: return "\(organization) is approved. Request a sign-in link with your work email to open the portal."
        case .rejected: return "\(organization) wasn’t approved. Contact DAD support if you have questions."
        case .other: return "We’re updating the status of your application for \(organization). Check back soon."
        }
    }

    public var title: String {
        switch state {
        case .pending: return "Application under review"
        case .approved: return "Application approved"
        case .rejected: return "Application not approved"
        case .other: return "Application status"
        }
    }
}

public protocol ApplicationStatusService: Sendable {
    /// The status of the application this install holds a receipt for, or nil when it holds none (or the
    /// server no longer recognizes it, which also forgets it).
    func status() async throws -> ApplicationStatusInfo?
    /// Forgets the receipt once the applicant has been shown a decision.
    func discardReceipt() throws
}

extension ApplicationStatusService {
    public func discardReceipt() throws {}
}

/// Reads `applicationStatus` with the stored receipt as the bearer. The receipt is the only thing kept, in its
/// own item apart from the donor and partner sessions. It is never logged or shown.
public struct WireApplicationStatus: ApplicationStatusService {
    private let origin: URL
    private let transport: any ClientTransport
    private let receipt: any CredentialStore

    public init(origin: URL, receipt: any CredentialStore) throws {
        guard origin.isBareHTTPSOrigin else { throw AccountError.invalidConfiguration }
        self.init(origin: origin, transport: makeNativeTransport(), receipt: receipt)
    }

    init(origin: URL, transport: any ClientTransport, receipt: any CredentialStore) {
        self.origin = origin; self.transport = transport; self.receipt = receipt
    }

    /// Whether a receipt is kept, so the UI can skip the section entirely when there is nothing to show.
    public var hasReceipt: Bool { ((try? receipt.load()) ?? nil) != nil }

    public func discardReceipt() throws { try receipt.clear() }

    public func status() async throws -> ApplicationStatusInfo? {
        guard let kept = try receipt.load() else { return nil }
        let client = Client(serverURL: origin, transport: transport, middlewares: [NativeHeaders(access: { kept.access })])
        return try await mappingUndecodableStatus {
            switch try await client.applicationStatus(.init()) {
            case .ok(let response):
                let body = try response.body.json
                return ApplicationStatusInfo(organization: body.organization, state: ApplicationState(contract: body.status))
            case .unauthorized:
                // Unknown or expired receipt: there is no application to show, and the receipt is useless.
                try receipt.clear()
                return nil
            case .tooManyRequests: throw AccountError.rateLimited
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            default: throw AccountError.unavailable
            }
        }
    }
}

@MainActor
@Observable
public final class ApplicationStatusModel {
    public enum Phase: Sendable, Equatable {
        case loading
        /// No receipt, or the server no longer knows it: show nothing.
        case none
        case loaded(ApplicationStatusInfo)
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    private let service: any ApplicationStatusService

    public init(service: any ApplicationStatusService) { self.service = service }

    /// A cancelled read keeps whatever was showing; a failed one never replaces a status already read.
    public func load() async {
        let prior = phase
        do {
            if let info = try await service.status() {
                phase = .loaded(info)
                // A decision is shown once; keeping the receipt would only keep the old card on the sign-in screen.
                if info.state == .approved || info.state == .rejected { try? service.discardReceipt() }
            } else { phase = .none }
        } catch where error.isCancellation {
            phase = prior
        } catch {
            if case .loaded = prior { return }
            phase = .failed(error.userMessage)
        }
    }
}
