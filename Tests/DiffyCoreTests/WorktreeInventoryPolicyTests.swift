import XCTest
@testable import DiffyCore

final class WorktreeInventoryPolicyTests: XCTestCase {
    func testThreeManualSiblingsProduceNoAutoChildren() {
        let groupID = UUID()
        let deployment = repo("deployment", path: "/tmp/ablafemx", groupID: groupID)
        let free = repo("free", path: "/tmp/ablafemx-free", groupID: groupID)
        let main = repo("main", path: "/tmp/ablafemx-main", groupID: groupID)
        let repositories = [deployment, free, main]
        let entries = [
            entry("/tmp/ablafemx", branch: "deployment-branch"),
            entry("/tmp/ablafemx-free", branch: "free-version"),
            entry("/tmp/ablafemx-main", branch: "main")
        ]

        XCTAssertEqual(WorktreeInventoryPolicy.familyOwnerID(repositories: repositories, entries: entries), deployment.id)
        XCTAssertTrue(WorktreeInventoryPolicy.desiredAutoManagedChildren(parent: deployment, repositories: repositories, entries: entries).isEmpty)
        XCTAssertTrue(WorktreeInventoryPolicy.desiredAutoManagedChildren(parent: free, repositories: repositories, entries: entries).isEmpty)
        XCTAssertTrue(WorktreeInventoryPolicy.desiredAutoManagedChildren(parent: main, repositories: repositories, entries: entries).isEmpty)
    }

    func testOwnerAutoShowsOnlyUnaddedSiblings() {
        let groupID = UUID()
        let deployment = repo("deployment", path: "/tmp/ablafemx", groupID: groupID)
        let free = repo("free", path: "/tmp/ablafemx-free", groupID: groupID)
        let repositories = [deployment, free]
        let entries = [
            entry("/tmp/ablafemx", branch: "deployment-branch"),
            entry("/tmp/ablafemx-free", branch: "free-version"),
            entry("/tmp/ablafemx-main", branch: "main")
        ]

        let desired = WorktreeInventoryPolicy.desiredAutoManagedChildren(parent: deployment, repositories: repositories, entries: entries)

        XCTAssertEqual(desired.map(\.canonicalPath), ["/tmp/ablafemx-main"])
        XCTAssertEqual(desired.first?.entry.branch, .branch("main"))
    }

    func testNonOwnerDoesNotAutoShowUnaddedSiblings() {
        let groupID = UUID()
        let deployment = repo("deployment", path: "/tmp/ablafemx", groupID: groupID)
        let free = repo("free", path: "/tmp/ablafemx-free", groupID: groupID)
        let repositories = [deployment, free]
        let entries = [
            entry("/tmp/ablafemx", branch: "deployment-branch"),
            entry("/tmp/ablafemx-free", branch: "free-version"),
            entry("/tmp/ablafemx-main", branch: "main")
        ]

        XCTAssertTrue(WorktreeInventoryPolicy.desiredAutoManagedChildren(parent: free, repositories: repositories, entries: entries).isEmpty)
    }

    func testDuplicatePathCleanupPrefersUserManagedRows() {
        let groupID = UUID()
        let parent = repo("parent", path: "/tmp/parent", groupID: groupID)
        let auto = repo("auto", path: "/tmp/wt", groupID: groupID, parentID: parent.id, isAutoManaged: true)
        let user = repo("user", path: "/tmp/wt", groupID: groupID)

        let ids = WorktreeInventoryPolicy.duplicateRepositoryIDsToRemove(repositories: [auto, user])

        XCTAssertEqual(ids, [auto.id])
    }

    func testDuplicatePathCleanupKeepsFirstAutoManagedRowWhenNoUserRowExists() {
        let groupID = UUID()
        let parent = repo("parent", path: "/tmp/parent", groupID: groupID)
        let first = repo("first", path: "/tmp/wt", groupID: groupID, parentID: parent.id, isAutoManaged: true)
        let second = repo("second", path: "/tmp/wt", groupID: groupID, parentID: parent.id, isAutoManaged: true)

        let ids = WorktreeInventoryPolicy.duplicateRepositoryIDsToRemove(repositories: [first, second])

        XCTAssertEqual(ids, [second.id])
    }

    func testMainWorktreeRowOwnsTheFamilyEvenWhenAddedLater() {
        let groupID = UUID()
        let feat = repo("feat", path: "/tmp/ablafemx-feat", groupID: groupID)
        let main = repo("ablafemx", path: "/tmp/ablafemx", groupID: groupID)
        let repositories = [feat, main]
        let entries = [
            entry("/tmp/ablafemx", branch: "deployment-branch"),
            entry("/tmp/ablafemx-feat", branch: "test-prune"),
            entry("/tmp/t3/dolfinx", branch: "upgrade/dolfinx-port")
        ]

        XCTAssertEqual(WorktreeInventoryPolicy.familyOwnerID(repositories: repositories, entries: entries), main.id)
        XCTAssertEqual(
            WorktreeInventoryPolicy.desiredAutoManagedChildren(parent: main, repositories: repositories, entries: entries).map(\.canonicalPath),
            ["/tmp/t3/dolfinx"]
        )
        XCTAssertTrue(WorktreeInventoryPolicy.desiredAutoManagedChildren(parent: feat, repositories: repositories, entries: entries).isEmpty)
    }

    func testRowGitListsFirstOwnsTheFamilyWhenMainWorktreeIsNotAdded() {
        let groupID = UUID()
        let free = repo("free", path: "/tmp/ablafemx-free", groupID: groupID)
        let feat = repo("feat", path: "/tmp/ablafemx-feat", groupID: groupID)
        let entries = [
            entry("/tmp/ablafemx", branch: "deployment-branch"),
            entry("/tmp/ablafemx-feat", branch: "test-prune"),
            entry("/tmp/ablafemx-free", branch: "free-version")
        ]

        XCTAssertEqual(WorktreeInventoryPolicy.familyOwnerID(repositories: [free, feat], entries: entries), feat.id)
        XCTAssertEqual(WorktreeInventoryPolicy.familyOwnerID(repositories: [feat, free], entries: entries), feat.id, "display order doesn't matter")
    }

    func testDismissedWorktreeIsNotRediscovered() {
        let groupID = UUID()
        var main = repo("main", path: "/tmp/repo", groupID: groupID)
        main.dismissedWorktrees = [DismissedWorktree(path: "/tmp/wt", branch: "feature")]
        let entries = [
            entry("/tmp/repo", branch: "main"),
            entry("/tmp/wt", branch: "feature"),
            entry("/tmp/other", branch: "other")
        ]

        let desired = WorktreeInventoryPolicy.desiredAutoManagedChildren(parent: main, repositories: [main], entries: entries)

        XCTAssertEqual(desired.map(\.canonicalPath), ["/tmp/other"])
        XCTAssertTrue(WorktreeInventoryPolicy.staleDismissals(of: main, entries: entries).isEmpty)
    }

    func testDismissalOnAnyFamilyRowApplies() {
        let groupID = UUID()
        let main = repo("main", path: "/tmp/repo", groupID: groupID)
        var feat = repo("feat", path: "/tmp/repo-feat", groupID: groupID)
        feat.dismissedWorktrees = [DismissedWorktree(path: "/tmp/wt", branch: "feature")]
        let entries = [
            entry("/tmp/repo", branch: "main"),
            entry("/tmp/repo-feat", branch: "feat"),
            entry("/tmp/wt", branch: "feature")
        ]

        XCTAssertTrue(WorktreeInventoryPolicy.desiredAutoManagedChildren(parent: main, repositories: [main, feat], entries: entries).isEmpty)
    }

    func testDismissalLapsesWhenAnotherBranchIsCheckedOutThere() {
        let groupID = UUID()
        var main = repo("main", path: "/tmp/repo", groupID: groupID)
        main.dismissedWorktrees = [DismissedWorktree(path: "/tmp/wt", branch: "feature")]
        let entries = [
            entry("/tmp/repo", branch: "main"),
            entry("/tmp/wt", branch: "next")
        ]

        let desired = WorktreeInventoryPolicy.desiredAutoManagedChildren(parent: main, repositories: [main], entries: entries)

        XCTAssertEqual(desired.map(\.canonicalPath), ["/tmp/wt"])
        XCTAssertEqual(WorktreeInventoryPolicy.staleDismissals(of: main, entries: entries), main.dismissedWorktrees)
    }

    func testDismissalHoldsThroughDetachedHead() {
        let groupID = UUID()
        var main = repo("main", path: "/tmp/repo", groupID: groupID)
        main.dismissedWorktrees = [DismissedWorktree(path: "/tmp/wt", branch: "feature")]
        let entries = [
            entry("/tmp/repo", branch: "main"),
            WorktreeEntry(path: "/tmp/wt", branch: .detached(shortSHA: "abc1234"))
        ]

        XCTAssertTrue(WorktreeInventoryPolicy.desiredAutoManagedChildren(parent: main, repositories: [main], entries: entries).isEmpty)
        XCTAssertTrue(WorktreeInventoryPolicy.staleDismissals(of: main, entries: entries).isEmpty)
    }

    func testDismissalOfRemovedWorktreeIsStale() {
        let groupID = UUID()
        var main = repo("main", path: "/tmp/repo", groupID: groupID)
        main.dismissedWorktrees = [DismissedWorktree(path: "/tmp/wt", branch: nil)]

        let stale = WorktreeInventoryPolicy.staleDismissals(of: main, entries: [entry("/tmp/repo", branch: "main")])

        XCTAssertEqual(stale, main.dismissedWorktrees)
    }

    private func repo(
        _ name: String,
        path: String,
        groupID: UUID,
        parentID: UUID? = nil,
        isAutoManaged: Bool = false
    ) -> RepositoryConfig {
        RepositoryConfig(
            displayName: name,
            path: path,
            groupID: groupID,
            parentRepositoryID: parentID,
            isAutoManaged: isAutoManaged
        )
    }

    private func entry(_ path: String, branch: String) -> WorktreeEntry {
        WorktreeEntry(path: path, branch: .branch(branch))
    }
}
