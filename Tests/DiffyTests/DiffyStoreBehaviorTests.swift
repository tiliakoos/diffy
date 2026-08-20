import Combine
import Foundation
import XCTest
import DiffyCore
@testable import Diffy

@MainActor
final class DiffyStoreBehaviorTests: XCTestCase {
    func testVisibleChildRemainsOrderedWhenParentIsHidden() throws {
        let group = RepositoryGroup(name: "Group")
        let parent = RepositoryConfig(
            displayName: "parent",
            path: "/tmp/parent",
            groupID: group.id,
            isHidden: true
        )
        let child = RepositoryConfig(
            displayName: "child",
            path: "/tmp/child",
            groupID: group.id,
            parentRepositoryID: parent.id,
            isAutoManaged: true
        )
        let storageURL = try writeState(groups: [group], repositories: [parent, child])
        let store = DiffyStore(storageURL: storageURL)

        store.load()

        XCTAssertEqual(store.orderedRepositories(in: group.id, includeHidden: false).map(\.id), [child.id])
    }

    func testHiddenChildStaysExcludedFromVisibleOrdering() throws {
        let group = RepositoryGroup(name: "Group")
        let parent = RepositoryConfig(displayName: "parent", path: "/tmp/parent", groupID: group.id)
        let child = RepositoryConfig(
            displayName: "child",
            path: "/tmp/child",
            groupID: group.id,
            isHidden: true,
            parentRepositoryID: parent.id,
            isAutoManaged: true
        )
        let storageURL = try writeState(groups: [group], repositories: [parent, child])
        let store = DiffyStore(storageURL: storageURL)

        store.load()

        XCTAssertEqual(store.orderedRepositories(in: group.id, includeHidden: false).map(\.id), [parent.id])
    }

    func testInvalidRepositoryPathDoesNotCreateRows() throws {
        let tempDir = try makeTemporaryDirectory()
        let store = DiffyStore(storageURL: tempDir.appendingPathComponent("repositories.json"))
        let invalidRepo = tempDir.appendingPathComponent("not-a-repo")
        try FileManager.default.createDirectory(at: invalidRepo, withIntermediateDirectories: true)

        store.addRepository(path: invalidRepo.path, destination: .newGroup)

        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertTrue(store.repositories.isEmpty)
        XCTAssertEqual(store.lastAddError, "Not a readable git repository: \(invalidRepo.path)")
    }

    func testAddingRepositoryUsesSelectedExistingGroup() throws {
        let tempDir = try makeTemporaryDirectory()
        let repositoryURL = tempDir.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try runGit(["init"], in: repositoryURL)

        let group = RepositoryGroup(name: "Existing")
        let storageURL = try writeState(groups: [group], repositories: [])
        let store = DiffyStore(storageURL: storageURL)
        defer { store.stop() }
        store.load()

        store.addRepository(path: repositoryURL.path, destination: .existingGroup(group.id))

        XCTAssertEqual(store.groups.map(\.id), [group.id])
        XCTAssertEqual(store.repositories.count, 1)
        XCTAssertEqual(store.repositories.first?.groupID, group.id)
    }

    func testAddingExistingAutoManagedPathPromotesWithoutCreatingDuplicate() throws {
        let tempDir = try makeTemporaryDirectory()
        let parentURL = tempDir.appendingPathComponent("parent")
        let childURL = tempDir.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)
        try runGit(["init"], in: parentURL)
        try runGit(["init"], in: childURL)

        let group = RepositoryGroup(name: "Group")
        let parent = RepositoryConfig(displayName: "parent", path: parentURL.path, groupID: group.id)
        let child = RepositoryConfig(
            displayName: "child",
            path: childURL.path,
            groupID: group.id,
            parentRepositoryID: parent.id,
            isAutoManaged: true
        )
        let storageURL = try writeState(groups: [group], repositories: [parent, child])
        let store = DiffyStore(storageURL: storageURL)
        defer { store.stop() }

        store.load()
        store.addRepository(path: childURL.path, destination: .existingGroup(group.id))

        XCTAssertEqual(store.repositories.count, 2)
        XCTAssertEqual(store.groups.count, 1)
        let promoted = try XCTUnwrap(store.repositories.first { $0.id == child.id })
        XCTAssertFalse(promoted.isAutoManaged)
        XCTAssertNil(promoted.parentRepositoryID)
        XCTAssertNil(store.lastAddError)
    }

    func testCorruptStateSetsPersistenceErrorAndDoesNotCreateRows() throws {
        let storageURL = try makeTemporaryDirectory().appendingPathComponent("repositories.json")
        try "{".write(to: storageURL, atomically: true, encoding: .utf8)
        let store = DiffyStore(storageURL: storageURL)

        store.load()

        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertTrue(store.repositories.isEmpty)
        XCTAssertNotNil(store.lastPersistenceError)
    }

    func testSaveFailureSetsPersistenceError() throws {
        let blockedParent = try makeTemporaryDirectory().appendingPathComponent("not-a-directory")
        try Data().write(to: blockedParent)
        let store = DiffyStore(storageURL: blockedParent.appendingPathComponent("repositories.json"))

        store.save()

        XCTAssertTrue(store.lastPersistenceError?.hasPrefix("Failed to save repositories:") == true)
    }

    func testRecentCommitLimitPersistsWithoutEagerHistoryLoading() throws {
        let group = RepositoryGroup(name: "Group")
        let repository = RepositoryConfig(displayName: "repo", path: "/tmp/repo", groupID: group.id)
        let storageURL = try writeState(groups: [group], repositories: [repository])
        let store = DiffyStore(storageURL: storageURL)
        store.load()

        XCTAssertNil(store.commitHistories[repository.id])
        store.updateRecentCommitLimit(for: repository.id, limit: 2)

        let persisted = try StoredStateMigration.decode(Data(contentsOf: storageURL))
        XCTAssertEqual(persisted.repositories.first?.recentCommitLimit, 2)
    }

    // MARK: - Removal cascades (git-free)

    func testRemoveRepositoryCascadesToAutoManagedChildren() throws {
        let group = RepositoryGroup(name: "Group")
        let parent = RepositoryConfig(displayName: "parent", path: "/tmp/parent", groupID: group.id)
        let child = RepositoryConfig(
            displayName: "child",
            path: "/tmp/child",
            groupID: group.id,
            parentRepositoryID: parent.id,
            isAutoManaged: true
        )
        let storageURL = try writeState(groups: [group], repositories: [parent, child])
        let store = DiffyStore(storageURL: storageURL)
        store.load()

        store.removeRepository(parent)

        XCTAssertTrue(store.repositories.isEmpty)
        XCTAssertNil(store.summaries[parent.id])
        XCTAssertNil(store.summaries[child.id])
        XCTAssertEqual(store.groups.count, 1, "Removing a repo preserves its now-empty group")
    }

    func testRemoveGroupDeleteReposCascadesToChildren() throws {
        let group = RepositoryGroup(name: "Group")
        let parent = RepositoryConfig(displayName: "parent", path: "/tmp/parent", groupID: group.id)
        let child = RepositoryConfig(
            displayName: "child",
            path: "/tmp/child",
            groupID: group.id,
            parentRepositoryID: parent.id,
            isAutoManaged: true
        )
        let storageURL = try writeState(groups: [group], repositories: [parent, child])
        let store = DiffyStore(storageURL: storageURL)
        store.load()

        store.removeGroup(group.id, mode: .deleteRepos)

        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertTrue(store.repositories.isEmpty)
    }

    func testRemoveGroupDissolveReassignsParentsAndChildrenToNewGroups() throws {
        let group = RepositoryGroup(name: "Shared")
        let parentA = RepositoryConfig(displayName: "A", path: "/tmp/a", groupID: group.id)
        let childA = RepositoryConfig(
            displayName: "A-wt", path: "/tmp/a-wt", groupID: group.id,
            parentRepositoryID: parentA.id, isAutoManaged: true
        )
        let parentB = RepositoryConfig(displayName: "B", path: "/tmp/b", groupID: group.id)
        let childB = RepositoryConfig(
            displayName: "B-wt", path: "/tmp/b-wt", groupID: group.id,
            parentRepositoryID: parentB.id, isAutoManaged: true
        )
        let storageURL = try writeState(groups: [group], repositories: [parentA, childA, parentB, childB])
        let store = DiffyStore(storageURL: storageURL)
        store.load()

        store.removeGroup(group.id, mode: .dissolveIntoStandalone)

        XCTAssertFalse(store.groups.contains { $0.id == group.id })
        XCTAssertEqual(store.groups.count, 2)
        XCTAssertEqual(store.repositories.count, 4)

        let a = try XCTUnwrap(store.repositories.first { $0.id == parentA.id })
        let aChild = try XCTUnwrap(store.repositories.first { $0.id == childA.id })
        let b = try XCTUnwrap(store.repositories.first { $0.id == parentB.id })
        let bChild = try XCTUnwrap(store.repositories.first { $0.id == childB.id })

        XCTAssertEqual(a.groupID, aChild.groupID, "Child follows its parent into the new group")
        XCTAssertEqual(b.groupID, bChild.groupID)
        XCTAssertNotEqual(a.groupID, b.groupID, "Each parent dissolves into its own standalone group")
        XCTAssertNotEqual(a.groupID, group.id, "Reassigned away from the dissolved group")
    }

    // MARK: - Worktree reconcile (real git)

    func testAddingParentAutoDiscoversLinkedWorktreeChild() throws {
        let (store, _, childURL) = try makeStoreWithDiscoveredWorktreeChild()
        defer { store.stop() }

        XCTAssertEqual(store.repositories.count, 2)
        let parent = try XCTUnwrap(store.repositories.first { !$0.isAutoManaged })
        let child = try XCTUnwrap(store.repositories.first { $0.isAutoManaged })
        XCTAssertEqual(child.parentRepositoryID, parent.id)
        XCTAssertEqual(child.groupID, parent.groupID)
        XCTAssertEqual(DiffyCore.canonicalPath(child.path), DiffyCore.canonicalPath(childURL.path))
    }

    func testRemovingWorktreePrunesAutoManagedChildOnRefresh() throws {
        let (store, repoURL, childURL) = try makeStoreWithDiscoveredWorktreeChild()
        defer { store.stop() }
        let parentID = try XCTUnwrap(store.repositories.first { !$0.isAutoManaged }).id

        try waitForRepositoryCount(store, count: 1) {
            try self.runGit(["worktree", "remove", childURL.path], in: repoURL)
            store.refresh(repositoryID: parentID)
        }

        XCTAssertEqual(store.repositories.count, 1)
        XCTAssertTrue(store.repositories.allSatisfy { !$0.isAutoManaged })
    }

    func testNewerRefreshWinsWhenOlderFinishesLast() throws {
        let repositoryURL = try makeTemporaryDirectory().appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)

        let group = RepositoryGroup(name: "Group")
        let repository = RepositoryConfig(displayName: "repo", path: repositoryURL.path, groupID: group.id)
        let storageURL = try writeState(groups: [group], repositories: [repository])
        let runner = DelayedRefreshRunner(repositoryPath: repositoryURL.path)
        let store = DiffyStore(storageURL: storageURL, gitClient: GitClient(runner: runner))
        defer {
            runner.releaseFirstRefresh()
            store.stop()
        }
        store.load()

        store.refresh(repositoryID: repository.id)
        XCTAssertTrue(runner.waitUntilFirstRefreshIsBlocked())

        let newerResult = expectation(description: "newer refresh result is applied")
        newerResult.assertForOverFulfill = false
        let newerResultCancellable = store.$summaries.sink { summaries in
            if summaries[repository.id]?.addedLines == 2 {
                newerResult.fulfill()
            }
        }
        defer { newerResultCancellable.cancel() }

        store.refresh(repositoryID: repository.id)
        wait(for: [newerResult], timeout: 2)

        let staleResult = expectation(description: "stale refresh result is ignored")
        staleResult.isInverted = true
        let staleResultCancellable = store.$summaries.sink { summaries in
            if summaries[repository.id]?.addedLines == 1 {
                staleResult.fulfill()
            }
        }
        defer { staleResultCancellable.cancel() }

        runner.releaseFirstRefresh()
        XCTAssertTrue(runner.waitUntilFirstRefreshFinishesReading())
        wait(for: [staleResult], timeout: 0.25)

        XCTAssertEqual(store.summaries[repository.id]?.addedLines, 2)
    }

    // MARK: - Popover history gate + poll tiers (stubbed git)

    func testRefreshLoadedRecentCommitsSkipsFreshUnchangedHistory() throws {
        let (store, group, repository, runner) = try makeStoreWithStubbedRunner()
        defer { store.stop() }

        waitForSummary(store, repositoryID: repository.id) {
            store.refreshAll()
        }
        waitForHistoryLoad(store, repositoryID: repository.id) {
            store.loadRecentCommits(repositoryID: repository.id)
        }
        XCTAssertEqual(runner.logCallCount, 1)
        XCTAssertNotNil(store.commitHistories[repository.id]?.fetchedAt)

        store.refreshLoadedRecentCommits(groupID: group.id)

        // A refetch would set `isLoading = true` synchronously; the gate must skip instead.
        XCTAssertEqual(store.commitHistories[repository.id]?.isLoading, false)
        XCTAssertEqual(runner.logCallCount, 1)
    }

    func testRefreshLoadedRecentCommitsRefetchesAfterMaterialChange() throws {
        let (store, group, repository, runner) = try makeStoreWithStubbedRunner()
        defer { store.stop() }

        waitForSummary(store, repositoryID: repository.id) {
            store.refreshAll()
        }
        waitForHistoryLoad(store, repositoryID: repository.id) {
            store.loadRecentCommits(repositoryID: repository.id)
        }

        runner.setUnstagedOutput("1\t0\tfile.txt\0")
        waitForSummary(store, repositoryID: repository.id, where: { $0.addedLines == 1 }) {
            store.refreshAll()
        }

        store.refreshLoadedRecentCommits(groupID: group.id)

        XCTAssertEqual(store.commitHistories[repository.id]?.isLoading, true)
        waitForHistoryLoad(store, repositoryID: repository.id) {}
        XCTAssertEqual(runner.logCallCount, 2)
    }

    func testPollTickRefreshesUnwatchedRepositories() throws {
        let (store, _, repository, _) = try makeStoreWithStubbedRunner()
        defer { store.stop() }

        // `start()` was never called, so no watchers exist — a non-sweep tick must refresh.
        waitForSummary(store, repositoryID: repository.id) {
            store.pollTick(1)
        }
    }

    /// One group + one repo backed by a real temp directory (paths must exist — `GitClient`
    /// checks `fileExists` before consulting the runner) and a `StubHistoryRunner`.
    private func makeStoreWithStubbedRunner() throws
        -> (store: DiffyStore, group: RepositoryGroup, repository: RepositoryConfig, runner: StubHistoryRunner) {
        let tempDir = try makeTemporaryDirectory()
        let repositoryURL = tempDir.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)

        let group = RepositoryGroup(name: "Group")
        let repository = RepositoryConfig(displayName: "repo", path: repositoryURL.path, groupID: group.id)
        let storageURL = try writeState(groups: [group], repositories: [repository])
        let runner = StubHistoryRunner()
        let store = DiffyStore(storageURL: storageURL, gitClient: GitClient(runner: runner))
        store.load()
        return (store, group, repository, runner)
    }

    /// Subscribe to `$summaries`, run `trigger`, and block until the repo's summary satisfies
    /// `predicate`.
    private func waitForSummary(
        _ store: DiffyStore,
        repositoryID: UUID,
        timeout: TimeInterval = 5,
        where predicate: @escaping (RepoDiffSummary) -> Bool = { _ in true },
        _ trigger: () -> Void
    ) {
        let expectation = XCTestExpectation(description: "summary for \(repositoryID)")
        expectation.assertForOverFulfill = false
        let cancellable = store.$summaries.sink { summaries in
            if let summary = summaries[repositoryID], predicate(summary) { expectation.fulfill() }
        }
        defer { cancellable.cancel() }
        trigger()
        wait(for: [expectation], timeout: timeout)
    }

    /// Run `trigger`, then subscribe to `$commitHistories` and block until the repo's history
    /// finishes loading. Triggering first matters: a `loadRecentCommits` call sets `isLoading`
    /// synchronously, so subscribing afterwards can't be fulfilled prematurely by a stale
    /// already-loaded current value.
    private func waitForHistoryLoad(
        _ store: DiffyStore,
        repositoryID: UUID,
        timeout: TimeInterval = 5,
        _ trigger: () -> Void
    ) {
        let expectation = XCTestExpectation(description: "history loaded for \(repositoryID)")
        expectation.assertForOverFulfill = false
        trigger()
        let cancellable = store.$commitHistories.sink { histories in
            if histories[repositoryID]?.isLoading == false { expectation.fulfill() }
        }
        defer { cancellable.cancel() }
        wait(for: [expectation], timeout: timeout)
    }

    /// Builds a temp repo with one commit + a linked `feature` worktree, points a fresh store at
    /// it, adds the repo, and waits until the auto-managed child row is reconciled into existence.
    private func makeStoreWithDiscoveredWorktreeChild() throws -> (store: DiffyStore, repoURL: URL, childURL: URL) {
        let tempDir = try makeTemporaryDirectory()
        let repoURL = tempDir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try runGit(["init"], in: repoURL)
        try runGit(["config", "user.email", "diffy@example.com"], in: repoURL)
        try runGit(["config", "user.name", "Diffy Tests"], in: repoURL)
        try "one\n".write(to: repoURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "tracked.txt"], in: repoURL)
        try runGit(["commit", "-m", "initial"], in: repoURL)

        let childURL = tempDir.appendingPathComponent("child")
        try runGit(["worktree", "add", "-b", "feature", childURL.path], in: repoURL)

        let store = DiffyStore(storageURL: tempDir.appendingPathComponent("repositories.json"))
        try waitForRepositoryCount(store, count: 2) {
            store.addRepository(path: repoURL.path, destination: .newGroup)
        }
        return (store, repoURL, childURL)
    }

    /// Subscribe to `$repositories`, run `trigger`, and block until the row count reaches `count`.
    /// Subscribing first guards against missing a fast synchronous mutation; over-fulfillment is
    /// tolerated because polling/FSEvents may re-emit the same count.
    private func waitForRepositoryCount(
        _ store: DiffyStore,
        count: Int,
        timeout: TimeInterval = 5,
        _ trigger: () throws -> Void
    ) throws {
        let expectation = XCTestExpectation(description: "repositories.count == \(count)")
        expectation.assertForOverFulfill = false
        let cancellable = store.$repositories.sink { repos in
            if repos.count == count { expectation.fulfill() }
        }
        defer { cancellable.cancel() }
        try trigger()
        wait(for: [expectation], timeout: timeout)
    }

    private func writeState(groups: [RepositoryGroup], repositories: [RepositoryConfig]) throws -> URL {
        let storageURL = try makeTemporaryDirectory().appendingPathComponent("repositories.json")
        let data = try JSONEncoder().encode(StoredState(groups: groups, repositories: repositories))
        try data.write(to: storageURL)
        return storageURL
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory

        let errorPipe = Pipe()
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTFail("git \(arguments.joined(separator: " ")) failed: \(error)")
        }
    }
}

/// Answers the refresh + recent-commit command set with canned output and counts `log`
/// invocations. Upstream lookup fails like a repo with no upstream (a benign early-return).
private final class StubHistoryRunner: GitProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _logCallCount = 0
    private var _unstagedOutput = ""

    var logCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _logCallCount
    }

    func setUnstagedOutput(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        _unstagedOutput = value
    }

    func run(_ command: GitCommand) throws -> String {
        if command.arguments.contains("log") {
            lock.lock(); defer { lock.unlock() }
            _logCallCount += 1
            return ""
        }
        if command.arguments.contains("@{upstream}") {
            throw GitClientError.commandFailed("no upstream")
        }
        if command.arguments.contains("--cached") {
            return ""
        }
        if command.arguments.contains("--numstat") {
            lock.lock(); defer { lock.unlock() }
            return _unstagedOutput
        }
        // hasHead rev-parse, worktree list, porcelain status: succeed with empty/trivial output.
        return ""
    }
}

private final class DelayedRefreshRunner: GitProcessRunning, @unchecked Sendable {
    private let repositoryPath: String
    private let lock = NSLock()
    private let firstRefreshBlocked = DispatchSemaphore(value: 0)
    private let firstRefreshRelease = DispatchSemaphore(value: 0)
    private let firstRefreshFinishedReading = DispatchSemaphore(value: 0)
    private var stagedCallCount = 0
    private var statusCallCount = 0

    init(repositoryPath: String) {
        self.repositoryPath = repositoryPath
    }

    func run(_ command: GitCommand) throws -> String {
        if command.arguments.contains("worktree"), command.arguments.contains("--porcelain") {
            let sha = String(repeating: "a", count: 40)
            return "worktree \(repositoryPath)\nHEAD \(sha)\nbranch refs/heads/main\n\n"
        }

        if command.arguments.contains("--cached") {
            lock.lock()
            stagedCallCount += 1
            let callNumber = stagedCallCount
            lock.unlock()

            if callNumber == 1 {
                firstRefreshBlocked.signal()
                guard firstRefreshRelease.wait(timeout: .now() + 2) == .success else {
                    throw GitClientError.commandFailed("Timed out waiting to release the first refresh")
                }
                return "1\t0\tfile.txt\0"
            }
            return "2\t0\tfile.txt\0"
        }

        if command.arguments.contains("--porcelain=v1") {
            lock.lock()
            statusCallCount += 1
            let callNumber = statusCallCount
            lock.unlock()

            if callNumber == 2 {
                firstRefreshFinishedReading.signal()
            }
        }

        return ""
    }

    func waitUntilFirstRefreshIsBlocked() -> Bool {
        firstRefreshBlocked.wait(timeout: .now() + 2) == .success
    }

    func releaseFirstRefresh() {
        firstRefreshRelease.signal()
    }

    func waitUntilFirstRefreshFinishesReading() -> Bool {
        firstRefreshFinishedReading.wait(timeout: .now() + 2) == .success
    }
}
