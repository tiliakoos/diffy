import XCTest
import DiffyCore
@testable import Diffy

final class AppColorTests: XCTestCase {
    func testBadgeColorAloneKeepsSystemDiffColors() {
        XCTAssertTrue(DiffColors.default.hasSystemDiffColors)
        XCTAssertTrue(
            DiffColors(
                additionHex: DiffColors.default.additionHex,
                removalHex: DiffColors.default.removalHex,
                badgeBackgroundHex: "#0433FF"
            ).hasSystemDiffColors
        )
        XCTAssertFalse(DiffColors(additionHex: "#11AA44", removalHex: DiffColors.default.removalHex).hasSystemDiffColors)
    }

    func testContrastingTextColorReadsOnDarkAndLightFills() throws {
        for dark in ["#0A2838", "#0433FF", "#942192"] {
            XCTAssertEqual(AppColor.contrastingTextColor(on: try XCTUnwrap(AppColor.nsColor(hex: dark))), .white, dark)
        }
        for light in ["#FFD60A", "#E5E5EA"] {
            XCTAssertEqual(AppColor.contrastingTextColor(on: try XCTUnwrap(AppColor.nsColor(hex: light))), .black, light)
        }
    }
}
