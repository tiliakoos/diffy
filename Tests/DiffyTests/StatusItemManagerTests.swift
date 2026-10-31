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

    // Frames measured on macOS 27: a `±` pill sits in a 44 pt item, `+1 / −1` in a 77 pt one,
    // and the item's right edge stays put while the menu bar moves its left edge.
    private let clean = CGRect(x: 1837, y: 1408, width: 44, height: 33)

    func testGrownBadgeThatMovedLeftIsPlaced() {
        let grown = CGRect(x: 1804, y: 1408, width: 77, height: 33)
        XCTAssertFalse(StatusItemPlacement.wasLeftInPlace(before: clean, after: grown))
    }

    func testGrownBadgeAtTheOldPositionWasLeftInPlace() {
        let grownInPlace = CGRect(x: 1837, y: 1408, width: 77, height: 33)
        XCTAssertTrue(StatusItemPlacement.wasLeftInPlace(before: clean, after: grownInPlace))
    }

    func testShrunkBadgeAtTheOldPositionWasLeftInPlace() {
        let grown = CGRect(x: 1804, y: 1408, width: 77, height: 33)
        let shrunkInPlace = CGRect(x: 1804, y: 1408, width: 44, height: 33)
        XCTAssertTrue(StatusItemPlacement.wasLeftInPlace(before: grown, after: shrunkInPlace))
        XCTAssertFalse(StatusItemPlacement.wasLeftInPlace(before: grown, after: clean))
    }

    func testSameWidthIsNeverFlagged() {
        XCTAssertFalse(StatusItemPlacement.wasLeftInPlace(before: clean, after: clean))
        // A neighbour to the right changed width: the whole item slid, which is not a missed layout.
        XCTAssertFalse(StatusItemPlacement.wasLeftInPlace(before: clean, after: clean.offsetBy(dx: -6, dy: 0)))
    }

    func testUnplacedFramesAreNeverFlagged() {
        let unplaced = CGRect(x: 0, y: 0, width: 44, height: 0)
        XCTAssertFalse(StatusItemPlacement.wasLeftInPlace(before: unplaced, after: CGRect(x: 0, y: 0, width: 77, height: 0)))
        XCTAssertFalse(StatusItemPlacement.wasLeftInPlace(before: unplaced, after: CGRect(x: 1804, y: 1408, width: 77, height: 33)))
        // At launch the window can have a height but still sit at the origin.
        let atOrigin = CGRect(x: 0, y: 0, width: 44, height: 33)
        XCTAssertFalse(StatusItemPlacement.wasLeftInPlace(before: atOrigin, after: CGRect(x: 0, y: 0, width: 93, height: 33)))
    }
}
