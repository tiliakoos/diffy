import XCTest
@testable import DiffyCore

final class GitProcessRunnerTests: XCTestCase {
    func testRunDrainsLargeStdoutWithoutDeadlock() throws {
        let command = GitCommand(
            executable: "/bin/sh",
            arguments: ["-c", "yes line | head -c 200000"]
        )
        let output = try GitProcessRunner().run(command)
        XCTAssertGreaterThanOrEqual(output.utf8.count, 200_000)
    }

    func testRunDrainsLargeStderrAndSurfacesItInError() {
        let command = GitCommand(
            executable: "/bin/sh",
            arguments: ["-c", "yes line | head -c 200000 1>&2; exit 1"]
        )
        do {
            _ = try GitProcessRunner().run(command)
            XCTFail("Expected commandFailed error")
        } catch let GitClientError.commandFailed(message) {
            XCTAssertGreaterThanOrEqual(message.utf8.count, 199_999)
        } catch {
            XCTFail("Expected GitClientError.commandFailed, got \(error)")
        }
    }

    func testRunTimesOutOnStalledProcess() {
        let command = GitCommand(executable: "/bin/sleep", arguments: ["60"])
        let start = Date()
        do {
            _ = try GitProcessRunner(timeout: 0.2).run(command)
            XCTFail("Expected commandFailed error")
        } catch let GitClientError.commandFailed(message) {
            XCTAssertTrue(message.contains("timed out"), "Unexpected message: \(message)")
            XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        } catch {
            XCTFail("Expected GitClientError.commandFailed, got \(error)")
        }
    }

    func testRunDecodesInvalidUTF8Lossily() throws {
        let command = GitCommand(
            executable: "/bin/sh",
            arguments: ["-c", "printf 'a\\351b\\n'"]
        )
        let output = try GitProcessRunner().run(command)
        XCTAssertEqual(output, "a\u{FFFD}b\n")
    }
}
