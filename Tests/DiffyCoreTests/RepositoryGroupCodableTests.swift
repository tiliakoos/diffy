import XCTest
@testable import DiffyCore

final class RepositoryGroupCodableTests: XCTestCase {
    func testRoundTripsAllFields() throws {
        let group = RepositoryGroup(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            name: "Frontend",
            diffColors: DiffColors(additionHex: "#11AA44", removalHex: "#DD3355", badgeBackgroundHex: "#223344"),
            badgeLabel: BadgeLabel(text: "fe", position: .leading),
            isHidden: true
        )

        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(RepositoryGroup.self, from: data)

        XCTAssertEqual(decoded.id, group.id)
        XCTAssertEqual(decoded.name, "Frontend")
        XCTAssertEqual(decoded.diffColors.additionHex, "#11AA44")
        XCTAssertEqual(decoded.diffColors.removalHex, "#DD3355")
        XCTAssertEqual(decoded.diffColors.badgeBackgroundHex, "#223344")
        XCTAssertEqual(decoded.badgeLabel?.text, "fe")
        XCTAssertEqual(decoded.badgeLabel?.position, .leading)
        XCTAssertTrue(decoded.isHidden)
    }

    func testRoundTripsWithoutBadgeLabel() throws {
        let group = RepositoryGroup(
            id: UUID(),
            name: "Unnamed",
            diffColors: .default,
            badgeLabel: nil
        )

        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(RepositoryGroup.self, from: data)

        XCTAssertNil(decoded.badgeLabel)
    }

    func testDecodesAllBadgeLabelPositions() throws {
        for position in BadgeLabelPosition.allCases {
            let label = BadgeLabel(text: "x", position: position)
            let data = try JSONEncoder().encode(label)
            let decoded = try JSONDecoder().decode(BadgeLabel.self, from: data)
            XCTAssertEqual(decoded.position, position)
        }
    }

    func testDecodesGroupWithMissingOptionalFields() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000020"
        }
        """

        let group = try JSONDecoder().decode(RepositoryGroup.self, from: Data(json.utf8))

        XCTAssertEqual(group.name, "")
        XCTAssertEqual(group.diffColors.additionHex, DiffColors.default.additionHex)
        XCTAssertNil(group.badgeLabel)
        XCTAssertFalse(group.isHidden)
    }
}
