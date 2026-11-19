import XCTest
@testable import DiffyCore

final class RepositoryOrderingTests: XCTestCase {
    private let group = UUID()
    private let otherGroup = UUID()

    func testReorderPermutesSiblingSlotsAndLeavesOtherRowsInPlace() throws {
        let a = row("a"), b = row("b"), c = row("c")
        let elsewhere = row("x", group: otherGroup)
        let child = row("a1", parent: a)
        let rows = [a, elsewhere, b, child, c]

        let result = try XCTUnwrap(RepositoryOrdering.reorder(rows, siblings: [c.id, a.id, b.id]))

        XCTAssertEqual(result.map(\.displayName), ["c", "x", "a", "a1", "b"])
    }

    func testReorderRejectsRowsThatAreNotSiblings() {
        let a = row("a"), b = row("b")
        let child = row("a1", parent: a)
        let elsewhere = row("x", group: otherGroup)

        XCTAssertNil(RepositoryOrdering.reorder([a, b, child], siblings: [child.id, a.id]))
        XCTAssertNil(RepositoryOrdering.reorder([a, b, elsewhere], siblings: [elsewhere.id, a.id]))
        XCTAssertNil(RepositoryOrdering.reorder([a, b], siblings: [b.id, UUID()]))
    }

    func testFlatMoveOfParentCarriesChildrenAndSnapsPastAnotherFamily() throws {
        let a = row("a"), b = row("b"), c = row("c")
        let b1 = row("b1", parent: b), b2 = row("b2", parent: b)
        let flat = [a, b, b1, b2, c]

        // Dropping `a` between b1 and b2 lands it after b's whole family.
        XCTAssertEqual(RepositoryOrdering.siblingOrder(moving: a.id, toFlatIndex: 3, in: flat), [b.id, a.id, c.id])
        XCTAssertEqual(RepositoryOrdering.siblingOrder(moving: c.id, toFlatIndex: 0, in: flat), [c.id, a.id, b.id])
        XCTAssertNil(RepositoryOrdering.siblingOrder(moving: a.id, toFlatIndex: 1, in: flat), "dropping where it started")
    }

    func testFlatMoveOfChildStaysWithinItsParent() throws {
        let a = row("a"), b = row("b")
        let b1 = row("b1", parent: b), b2 = row("b2", parent: b), b3 = row("b3", parent: b)
        let flat = [a, b, b1, b2, b3]

        XCTAssertEqual(RepositoryOrdering.siblingOrder(moving: b3.id, toFlatIndex: 0, in: flat), [b3.id, b1.id, b2.id])
        XCTAssertEqual(RepositoryOrdering.siblingOrder(moving: b1.id, toFlatIndex: 5, in: flat), [b2.id, b3.id, b1.id])
        XCTAssertEqual(RepositoryOrdering.siblingOrder(moving: b1.id, toFlatIndex: 4, in: flat), [b2.id, b1.id, b3.id])
    }

    func testMoveByOffsetClampsAtTheEnds() {
        let a = row("a"), b = row("b"), c = row("c")
        let a1 = row("a1", parent: a)
        let flat = [a, a1, b, c]

        XCTAssertEqual(RepositoryOrdering.siblingOrder(moving: c.id, by: -1, in: flat), [a.id, c.id, b.id])
        XCTAssertEqual(RepositoryOrdering.siblingOrder(moving: c.id, by: -10, in: flat), [c.id, a.id, b.id])
        XCTAssertNil(RepositoryOrdering.siblingOrder(moving: a.id, by: -1, in: flat))
        XCTAssertNil(RepositoryOrdering.siblingOrder(moving: a1.id, by: 1, in: flat), "an only child has nowhere to go")
    }

    private func row(_ name: String, group: UUID? = nil, parent: RepositoryConfig? = nil) -> RepositoryConfig {
        RepositoryConfig(
            displayName: name,
            path: "/tmp/\(name)",
            groupID: group ?? parent?.groupID ?? self.group,
            parentRepositoryID: parent?.id,
            isAutoManaged: parent != nil
        )
    }
}
