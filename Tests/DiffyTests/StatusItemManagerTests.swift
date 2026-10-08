import XCTest
import DiffyCore
@testable import Diffy

final class StatusItemManagerTests: XCTestCase {
    private func state(
        displayName: String = "Group",
        added: Int = 0,
        removed: Int = 0,
        errorCount: Int = 0,
        interface: Interface = .modern
    ) -> BadgeState {
        BadgeState(
            displayName: displayName,
            added: added,
            removed: removed,
            visibleRepoCount: 1,
            colors: .default,
            badgeLabel: nil,
            errorCount: errorCount,
            interface: interface
        )
    }

    func testBadgeStateChangesWhenDisplayNameChanges() {
        XCTAssertNotEqual(state(displayName: "Old", added: 1, removed: 2), state(displayName: "New", added: 1, removed: 2))
    }

    func testBadgeStateChangesWhenErrorCountChanges() {
        XCTAssertNotEqual(state(errorCount: 0), state(errorCount: 1))
        XCTAssertNotEqual(state(errorCount: 1), state(errorCount: 2))
    }

    func testBadgeStateChangesWhenInterfaceChanges() {
        XCTAssertNotEqual(state(interface: .modern), state(interface: .classic))
    }
}
