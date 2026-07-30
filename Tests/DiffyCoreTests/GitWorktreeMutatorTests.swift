import XCTest
@testable import DiffyCore

final class GitWorktreeMutatorTests: XCTestCase {
    func testEmitsExactRemoveCommandWithoutForce() throws {
        let recorder = RecordingRunner()
        let mutator = GitWorktreeMutator(runner: recorder)

        try mutator.remove(parentPath: "/p", worktreePath: "/p/wt1")

        XCTAssertEqual(recorder.commands.count, 1)
        let cmd = try XCTUnwrap(recorder.commands.first)
        XCTAssertEqual(cmd.arguments, ["-C", "/p", "worktree", "remove", "/p/wt1"])
        XCTAssertFalse(cmd.arguments.contains("--force"))
        XCTAssertFalse(cmd.arguments.contains("-f"))
        XCTAssertEqual(cmd.executable, "/usr/bin/git")
    }

    func testPropagatesRunnerError() {
        let recorder = RecordingRunner(stubError: GitClientError.commandFailed("dirty working tree"))
        let mutator = GitWorktreeMutator(runner: recorder)

        XCTAssertThrowsError(try mutator.remove(parentPath: "/p", worktreePath: "/p/wt2")) { error in
            guard let gitError = error as? GitClientError else {
                XCTFail("Expected GitClientError, got \(type(of: error))")
                return
            }
            switch gitError {
            case .commandFailed(let message):
                XCTAssertEqual(message, "dirty working tree")
            case .invalidRepository:
                XCTFail("Expected commandFailed, got invalidRepository")
            case .invalidCommit:
                XCTFail("Expected commandFailed, got invalidCommit")
            }
        }
    }
}

private final class RecordingRunner: GitProcessRunning, @unchecked Sendable {
    var commands: [GitCommand] = []
    let stubError: Error?

    init(stubError: Error? = nil) {
        self.stubError = stubError
    }

    func run(_ command: GitCommand) throws -> String {
        commands.append(command)
        if let stubError {
            throw stubError
        }
        return ""
    }
}
