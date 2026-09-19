import XCTest
@testable import DiffyCore

final class GitClientIntegrationTests: XCTestCase {
    func testRecentCommitsClassifiesPushedAndLocalOnlyAndHonorsLimit() throws {
        let repo = try TemporaryGitRepository()
        let remote = repo.url.deletingLastPathComponent().appendingPathComponent("remote-" + UUID().uuidString + ".git")
        defer { try? FileManager.default.removeItem(at: remote) }
        try repo.git("init", "--bare", remote.path)

        try repo.write("tracked.txt", contents: "one\n")
        try repo.git("add", "tracked.txt")
        try repo.git("commit", "-m", "pushed 🚀")
        try repo.git("remote", "add", "origin", remote.path)
        try repo.git("push", "-u", "origin", "HEAD")

        try repo.write("local.txt", contents: "two\n")
        try repo.git("add", "local.txt")
        try repo.git("commit", "-m", "local")

        let config = RepositoryConfig(displayName: "Temp", path: repo.path, groupID: UUID())
        let commits = try GitClient().recentCommits(config, limit: 5)
        let limited = try GitClient().recentCommits(config, limit: 1)
        let rootFiles = try GitClient().commitDetails(config, sha: commits[1].sha)

        XCTAssertEqual(commits.map(\.subject), ["local", "pushed 🚀"])
        guard case .localOnly(let localUpstream) = commits[0].publicationStatus else {
            return XCTFail("Newest commit should be local only")
        }
        guard case .onUpstream(let pushedUpstream) = commits[1].publicationStatus else {
            return XCTFail("Initial commit should be on upstream")
        }
        XCTAssertEqual(localUpstream, pushedUpstream)
        XCTAssertTrue(localUpstream.hasPrefix("origin/"))
        XCTAssertEqual(limited.map(\.subject), ["local"])
        XCTAssertEqual(rootFiles.first?.status, .added)
        XCTAssertEqual(rootFiles.first?.path, "tracked.txt")
    }

    func testCommitDetailsRejectsNonSHARevision() {
        let config = RepositoryConfig(displayName: "Temp", path: "/tmp", groupID: UUID())

        XCTAssertThrowsError(try GitClient().commitDetails(config, sha: "HEAD")) { error in
            XCTAssertEqual(error.localizedDescription, "Invalid commit identifier: HEAD")
        }
    }

    func testDiscoversWorktreesIncludingBranchAndDetachedStates() throws {
        let repo = try TemporaryGitRepository()
        try repo.write("tracked.txt", contents: "one\n")
        try repo.git("add", "tracked.txt")
        try repo.git("commit", "-m", "initial")

        let featureWT = repo.url.deletingLastPathComponent().appendingPathComponent("wt-feature-" + UUID().uuidString)
        let detachedWT = repo.url.deletingLastPathComponent().appendingPathComponent("wt-detached-" + UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: featureWT)
            try? FileManager.default.removeItem(at: detachedWT)
        }

        try repo.git("worktree", "add", featureWT.path, "-b", "feature")
        try repo.git("worktree", "add", "--detach", detachedWT.path, "HEAD")

        let entries = try GitClient().discoverWorktrees(parentPath: repo.path)
        XCTAssertEqual(entries.count, 3)

        let canonicalMain = DiffyCore.canonicalPath(repo.path)
        let canonicalFeature = DiffyCore.canonicalPath(featureWT.path)
        let canonicalDetached = DiffyCore.canonicalPath(detachedWT.path)

        let mainEntry = try XCTUnwrap(entries.first { DiffyCore.canonicalPath($0.path) == canonicalMain })
        switch mainEntry.branch {
        case .branch(let name):
            XCTAssertTrue(name == "main" || name == "master", "Unexpected default branch: \(name)")
        default:
            XCTFail("Main worktree should be on a branch, got \(mainEntry.branch)")
        }

        let featureEntry = try XCTUnwrap(entries.first { DiffyCore.canonicalPath($0.path) == canonicalFeature })
        XCTAssertEqual(featureEntry.branch, .branch("feature"))

        let detachedEntry = try XCTUnwrap(entries.first { DiffyCore.canonicalPath($0.path) == canonicalDetached })
        if case .detached(let sha) = detachedEntry.branch {
            XCTAssertEqual(sha.count, 7, "Short SHA should be 7 chars")
        } else {
            XCTFail("Detached worktree should report detached, got \(detachedEntry.branch)")
        }
    }

    func testDiscoveringFromLinkedWorktreeReturnsSameFamilyWithMainFirst() throws {
        let repo = try TemporaryGitRepository()
        try repo.write("tracked.txt", contents: "one\n")
        try repo.git("add", "tracked.txt")
        try repo.git("commit", "-m", "initial")

        let featureWT = repo.url.deletingLastPathComponent().appendingPathComponent("wt-feature-" + UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: featureWT)
        }

        try repo.git("worktree", "add", featureWT.path, "-b", "feature")

        let fromMain = try GitClient().discoverWorktrees(parentPath: repo.path)
        let fromLinked = try GitClient().discoverWorktrees(parentPath: featureWT.path)

        XCTAssertEqual(fromLinked.map { DiffyCore.canonicalPath($0.path) }, fromMain.map { DiffyCore.canonicalPath($0.path) })
        XCTAssertEqual(DiffyCore.canonicalPath(fromLinked[0].path), DiffyCore.canonicalPath(repo.path))
    }


    func testSummarizeCountsUntrackedSymlinkAsOneTextLine() throws {
        let repo = try TemporaryGitRepository()
        try repo.write("tracked.txt", contents: "one\n")
        try repo.git("add", "tracked.txt")
        try repo.git("commit", "-m", "initial")

        try FileManager.default.createSymbolicLink(
            atPath: repo.url.appendingPathComponent("link.txt").path,
            withDestinationPath: "tracked.txt"
        )

        let config = RepositoryConfig(displayName: "Temp", path: repo.path, groupID: UUID())
        let summary = try GitClient().summarize(config)

        let link = try XCTUnwrap(summary.unstagedFiles.first { $0.path == "link.txt" })
        XCTAssertEqual(link.addedLines, 1)
        XCTAssertFalse(link.isBinary)
    }

    func testSummarizeTreatsUnreadableUntrackedFileAsNonBinary() throws {
        try XCTSkipIf(geteuid() == 0, "Root can read permission-less files")
        let repo = try TemporaryGitRepository()
        try repo.write("tracked.txt", contents: "one\n")
        try repo.git("add", "tracked.txt")
        try repo.git("commit", "-m", "initial")

        try repo.write("secret.txt", contents: "hidden\n")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: repo.url.appendingPathComponent("secret.txt").path
        )

        let config = RepositoryConfig(displayName: "Temp", path: repo.path, groupID: UUID())
        let summary = try GitClient().summarize(config)

        let file = try XCTUnwrap(summary.unstagedFiles.first { $0.path == "secret.txt" })
        XCTAssertFalse(file.isBinary)
        XCTAssertEqual(file.addedLines, 0)
    }

    func testSummarizesTemporaryRepositoryAndReturnsToZeroAfterCommit() throws {
        let repo = try TemporaryGitRepository()
        try repo.write("tracked.txt", contents: "one\n")
        try repo.git("add", "tracked.txt")
        try repo.git("commit", "-m", "initial")

        try repo.write("tracked.txt", contents: "one\ntwo\nthree\n")
        try repo.write("staged.txt", contents: "alpha\nbeta\n")
        try repo.git("add", "staged.txt")
        try repo.write("untracked.txt", contents: "new\nfile\n")

        let config = RepositoryConfig(displayName: "Temp", path: repo.path, groupID: UUID())
        let summary = try GitClient().summarize(config)

        XCTAssertEqual(summary.stagedFiles.map(\.path), ["staged.txt"])
        XCTAssertEqual(summary.unstagedFiles.map(\.path), ["tracked.txt", "untracked.txt"])
        XCTAssertEqual(summary.unstagedFiles.first { $0.path == "untracked.txt" }?.displayStatus, "U")
        XCTAssertEqual(summary.addedLines, 6)
        XCTAssertEqual(summary.removedLines, 0)

        try repo.git("add", "tracked.txt", "untracked.txt")
        try repo.git("commit", "-m", "changes")

        let cleanSummary = try GitClient().summarize(config)
        XCTAssertEqual(cleanSummary.addedLines, 0)
        XCTAssertEqual(cleanSummary.removedLines, 0)
        XCTAssertTrue(cleanSummary.stagedFiles.isEmpty)
        XCTAssertTrue(cleanSummary.unstagedFiles.isEmpty)
    }
}

private final class TemporaryGitRepository {
    let url: URL

    var path: String {
        url.path
    }

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffyTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git("init")
        try git("config", "user.email", "diffy@example.com")
        try git("config", "user.name", "Diffy Tests")
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func write(_ relativePath: String, contents: String) throws {
        let fileURL = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    @discardableResult
    func git(_ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = url

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw XCTSkip("Temporary git command failed: git \(arguments.joined(separator: " ")) \(error)")
        }

        return output
    }
}
