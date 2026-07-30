import XCTest
import DiffyCore
@testable import Diffy

final class StatusItemManagerTests: XCTestCase {
    func testBadgeStateChangesWhenDisplayNameChanges() {
        let original = BadgeState(
            displayName: "Old",
            added: 1,
            removed: 2,
            visibleRepoCount: 1,
            colors: .default,
            badgeLabel: nil,
            errorCount: 0
        )
        let renamed = BadgeState(
            displayName: "New",
            added: 1,
            removed: 2,
            visibleRepoCount: 1,
            colors: .default,
            badgeLabel: nil,
            errorCount: 0
        )

        XCTAssertNotEqual(original, renamed)
    }

    func testBadgeStateChangesWhenErrorCountChanges() {
        let healthy = BadgeState(
            displayName: "Group",
            added: 0,
            removed: 0,
            visibleRepoCount: 1,
            colors: .default,
            badgeLabel: nil,
            errorCount: 0
        )
        let oneError = BadgeState(
            displayName: "Group",
            added: 0,
            removed: 0,
            visibleRepoCount: 1,
            colors: .default,
            badgeLabel: nil,
            errorCount: 1
        )
        let twoErrors = BadgeState(
            displayName: "Group",
            added: 0,
            removed: 0,
            visibleRepoCount: 1,
            colors: .default,
            badgeLabel: nil,
            errorCount: 2
        )

        XCTAssertNotEqual(healthy, oneError)
        XCTAssertNotEqual(oneError, twoErrors)
    }
}
