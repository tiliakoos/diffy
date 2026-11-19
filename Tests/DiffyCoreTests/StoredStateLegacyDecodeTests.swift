import XCTest
@testable import DiffyCore

final class StoredStateLegacyDecodeTests: XCTestCase {
    /// New fields on `RepositoryConfig` (`parentRepositoryID`, `isAutoManaged`, `recentCommitLimit`)
    /// must round-trip through encode/decode without losing values.
    /// Legacy decode paths (envelope without these fields, pre-groups array) are covered by
    /// `StoredStateMigrationTests` — extending them with these defaults works because the new
    /// fields use `decodeIfPresent`.
    func testCurrentEnvelopeWithNewFieldsRoundTrips() throws {
        let parentID = UUID()
        let groupID = UUID()
        let child = RepositoryConfig(
            id: UUID(),
            displayName: "wt-feature",
            path: "/tmp/wt-feature",
            groupID: groupID,
            isHidden: false,
            parentRepositoryID: parentID,
            isAutoManaged: true,
            recentCommitLimit: 12
        )
        let state = StoredState(
            groups: [RepositoryGroup(id: groupID, name: "g")],
            repositories: [child]
        )

        let encoded = try JSONEncoder().encode(state)
        let decoded = try StoredStateMigration.decode(encoded)

        XCTAssertEqual(decoded.repositories.count, 1)
        XCTAssertEqual(decoded.repositories[0].parentRepositoryID, parentID)
        XCTAssertTrue(decoded.repositories[0].isAutoManaged)
        XCTAssertEqual(decoded.repositories[0].recentCommitLimit, 12)
    }

    func testRecentCommitLimitClampsWhenDecodingMalformedState() throws {
        let group = RepositoryGroup(name: "g")
        let state = StoredState(
            groups: [group],
            repositories: [RepositoryConfig(displayName: "repo", path: "/tmp/repo", groupID: group.id)]
        )
        let encoded = try JSONEncoder().encode(state)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var repositories = try XCTUnwrap(object["repositories"] as? [[String: Any]])
        repositories[0]["recentCommitLimit"] = 99
        object["repositories"] = repositories

        let decoded = try StoredStateMigration.decode(JSONSerialization.data(withJSONObject: object))

        XCTAssertEqual(decoded.repositories[0].recentCommitLimit, 20)
    }

    func testDismissedWorktreesRoundTripAndDefaultToEmpty() throws {
        let group = RepositoryGroup(name: "g")
        let dismissals = [
            DismissedWorktree(path: "/tmp/wt", branch: "feature"),
            DismissedWorktree(path: "/tmp/detached", branch: nil)
        ]
        let withDismissals = RepositoryConfig(
            displayName: "repo",
            path: "/tmp/repo",
            groupID: group.id,
            dismissedWorktrees: dismissals
        )
        let without = RepositoryConfig(displayName: "other", path: "/tmp/other", groupID: group.id)

        let encoded = try JSONEncoder().encode(StoredState(groups: [group], repositories: [withDismissals, without]))
        let decoded = try StoredStateMigration.decode(encoded)

        XCTAssertEqual(decoded.repositories[0].dismissedWorktrees, dismissals)
        XCTAssertEqual(decoded.repositories[1].dismissedWorktrees, [])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let repositories = try XCTUnwrap(object["repositories"] as? [[String: Any]])
        XCTAssertNil(repositories[1]["dismissedWorktrees"], "empty list is not written, so older builds see the same file")
    }
}
