import Foundation
import XCTest
@testable import DADFoundation

final class RoleRouterTests: XCTestCase {
    func testStartsRestoringThenResolvesToUnauthenticated() {
        var router = RoleRouter()
        XCTAssertEqual(router.root, .restoring)
        router.restoredSignedOut()
        XCTAssertEqual(router.root, .unauthenticated(selectedRole: nil))
        XCTAssertNil(router.currentRole)
    }

    func testRoleSelectionThenSignInEntersAuthenticatedStack() {
        var router = RoleRouter(root: .unauthenticated(selectedRole: nil))
        router.selectRole(.partner)
        XCTAssertEqual(router.root, .unauthenticated(selectedRole: .partner))
        router.signedIn(as: .partner)
        XCTAssertEqual(router.root, .authenticated(.partner))
        XCTAssertEqual(router.currentRole, .partner)
    }

    func testSignOutClearsRoleAndPendingDestination() {
        var router = RoleRouter(root: .authenticated(.donor))
        _ = router.receive(.gifts) // signed in → not deferred
        router.signedOut()
        XCTAssertEqual(router.root, .unauthenticated(selectedRole: nil))
        XCTAssertNil(router.flushPendingDestination())
    }

    func testDeepLinkDeferredUntilSignedInThenFlushed() {
        var router = RoleRouter(root: .unauthenticated(selectedRole: .donor))
        // Not signed in: destination is deferred, nothing returned to navigate now.
        XCTAssertNil(router.receive(.dashboard))
        router.signedIn(as: .donor)
        XCTAssertEqual(router.flushPendingDestination(), .dashboard)
        // Flushed once.
        XCTAssertNil(router.flushPendingDestination())
    }

    func testDeepLinkWhileSignedInNavigatesImmediately() {
        var router = RoleRouter(root: .authenticated(.donor))
        XCTAssertEqual(router.receive(.profile), .profile)
    }

    func testRestoredSignedOutDoesNotClobberActiveSession() {
        var router = RoleRouter(root: .authenticated(.donor))
        router.restoredSignedOut()
        XCTAssertEqual(router.root, .authenticated(.donor))
    }
}
