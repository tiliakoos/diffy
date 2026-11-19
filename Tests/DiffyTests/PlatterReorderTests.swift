import DiffyCore
import XCTest
@testable import Diffy

final class PlatterReorderTests: XCTestCase {
    private let group = UUID()

    /// Three top-level rows, 50 pt tall with 6 pt gaps; `b` has a 40 pt child.
    private func layout() -> (rows: [RepositoryConfig], frames: [UUID: CGRect], a: RepositoryConfig, b: RepositoryConfig, b1: RepositoryConfig, c: RepositoryConfig) {
        let a = row("a"), b = row("b"), c = row("c")
        let b1 = row("b1", parent: b)
        let frames: [UUID: CGRect] = [
            a.id: CGRect(x: 0, y: 0, width: 300, height: 50),
            b.id: CGRect(x: 0, y: 56, width: 300, height: 50),
            b1.id: CGRect(x: 0, y: 112, width: 300, height: 40),
            c.id: CGRect(x: 0, y: 158, width: 300, height: 50),
        ]
        return ([a, b, b1, c], frames, a, b, b1, c)
    }

    func testDraggingAParentCarriesItsChildAndShiftsPassedSiblings() throws {
        let l = layout()
        var drag = try XCTUnwrap(PlatterReorder(id: l.b.id, rows: l.rows, frames: l.frames, spacing: 6, scrollOffset: 0))

        drag.pointerTranslation = -20 // b's top edge at 36, still below a's middle (25)
        XCTAssertEqual(drag.targetIndex(scrollOffset: 0), 1)
        drag.pointerTranslation = -80 // clamped to -56: top edge at 0, past a's middle
        XCTAssertEqual(drag.targetIndex(scrollOffset: 0), 0)
        XCTAssertEqual(drag.offset(for: l.b1.id, scrollOffset: 0), -56, "the child moves with its parent, clamped at the top")
        XCTAssertEqual(drag.offset(for: l.a.id, scrollOffset: 0), 102, "a slides down by b's family height plus a gap")
        XCTAssertEqual(drag.offset(for: l.c.id, scrollOffset: 0), 0)
        XCTAssertEqual(drag.restingTranslation(for: 0), -56)
        XCTAssertEqual(drag.order(droppingAt: 0), [l.b.id, l.a.id, l.c.id])
    }

    func testChildOnlyMovesAmongItsSiblingsAndOnlyChildCannotDrag() {
        let l = layout()
        XCTAssertNil(PlatterReorder(id: l.b1.id, rows: l.rows, frames: l.frames, spacing: 6, scrollOffset: 0))
    }

    func testScrollingDuringADragCountsTowardTheTranslation() throws {
        let l = layout()
        var drag = try XCTUnwrap(PlatterReorder(id: l.a.id, rows: l.rows, frames: l.frames, spacing: 6, scrollOffset: 10))
        drag.pointerTranslation = 20

        XCTAssertEqual(drag.translation(scrollOffset: 110), 120)
        XCTAssertEqual(drag.targetIndex(scrollOffset: 110), 1)
        XCTAssertEqual(drag.translation(scrollOffset: 1000), 158, "never past the last sibling")
        XCTAssertEqual(drag.targetIndex(scrollOffset: 1000), 2)
        XCTAssertEqual(drag.restingTranslation(for: 2), 158)
    }

    private func row(_ name: String, parent: RepositoryConfig? = nil) -> RepositoryConfig {
        RepositoryConfig(
            displayName: name,
            path: "/tmp/\(name)",
            groupID: group,
            parentRepositoryID: parent?.id,
            isAutoManaged: parent != nil
        )
    }
}
