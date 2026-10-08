import XCTest
import DiffyCore
@testable import Diffy

final class DistinctBranchTests: XCTestCase {
    private func repository(named name: String) -> RepositoryConfig {
        RepositoryConfig(displayName: name, path: "/tmp/\(name)", groupID: UUID())
    }

    func testHidesTheBranchARowIsNamedAfter() {
        let worktree = repository(named: "fix/9905-calendar-done")
        XCTAssertNil(distinctBranch(.branch("fix/9905-calendar-done"), for: worktree))
    }

    func testKeepsABranchThatDiffersFromTheName() {
        let repo = repository(named: "super-productivity")
        XCTAssertEqual(distinctBranch(.branch("features/tiliakoos"), for: repo), .branch("features/tiliakoos"))
    }

    func testKeepsDetachedAndBare() {
        let repo = repository(named: "abc1234")
        XCTAssertEqual(distinctBranch(.detached(shortSHA: "abc1234"), for: repo), .detached(shortSHA: "abc1234"))
        XCTAssertEqual(distinctBranch(.bare, for: repo), .bare)
    }

    func testHidesUnknownAndMissingBranches() {
        let repo = repository(named: "super-productivity")
        XCTAssertNil(distinctBranch(.unknown, for: repo))
        XCTAssertNil(distinctBranch(nil, for: repo))
    }
}
