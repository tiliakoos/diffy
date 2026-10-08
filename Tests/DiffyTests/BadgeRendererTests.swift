import XCTest
import DiffyCore
@testable import Diffy

final class BadgeRendererTests: XCTestCase {
    func testCountTextGroupsBelowTenThousand() {
        XCTAssertEqual(BadgeRenderer.countText(0), "0")
        XCTAssertEqual(BadgeRenderer.countText(999), "999")
        XCTAssertEqual(BadgeRenderer.countText(1108), "1,108")
        XCTAssertEqual(BadgeRenderer.countText(9999), "9,999")
    }

    func testCountTextAbbreviatesFromTenThousand() {
        XCTAssertEqual(BadgeRenderer.countText(10_000), "10k")
        XCTAssertEqual(BadgeRenderer.countText(12_400), "12.4k")
        XCTAssertEqual(BadgeRenderer.countText(12_449), "12.4k")
        XCTAssertEqual(BadgeRenderer.countText(1_000_000), "1,000k")
    }

    @MainActor
    func testModernCleanBadgeIsNarrowerThanCounts() {
        let clean = BadgeRenderer.image(added: 0, removed: 0, colors: .default, interface: .modern)
        let counts = BadgeRenderer.image(added: 1108, removed: 170, colors: .default, interface: .modern)

        XCTAssertLessThan(clean.size.width, counts.size.width)
        XCTAssertGreaterThanOrEqual(clean.size.height, 18)
    }

    @MainActor
    func testLabelWidensTheModernBadge() {
        let plain = BadgeRenderer.image(added: 1, removed: 1, colors: .default, interface: .modern)
        let labelled = BadgeRenderer.image(
            added: 1,
            removed: 1,
            colors: .default,
            badgeLabel: BadgeLabel(text: "S", position: .leading),
            interface: .modern
        )

        XCTAssertGreaterThan(labelled.size.width, plain.size.width)
    }

    @MainActor
    func testBadgeColorDrawsAPillAroundTheCounts() {
        let plain = BadgeRenderer.image(added: 1, removed: 1, colors: .default, interface: .modern)
        let colors = DiffColors(
            additionHex: DiffColors.default.additionHex,
            removalHex: DiffColors.default.removalHex,
            badgeBackgroundHex: "#0433FF"
        )
        let pill = BadgeRenderer.image(added: 1, removed: 1, colors: colors, interface: .modern)

        XCTAssertGreaterThan(pill.size.width, plain.size.width)
        XCTAssertGreaterThan(pill.size.height, plain.size.height)
    }
}
