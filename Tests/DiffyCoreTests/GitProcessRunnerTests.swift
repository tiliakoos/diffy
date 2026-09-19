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

    /// The app calls run() from many detached tasks at once (one per repo, several commands each).
    /// Waiting for exit on a shared Dispatch worker thread loses wakeups under that load and
    /// leaks a parked thread per miss, so every later run times out. Exercise that shape directly.
    func testConcurrentRunsFromDetachedTasksAllComplete() async {
        let runner = GitProcessRunner(timeout: 5)
        let command = GitCommand(executable: "/bin/sh", arguments: ["-c", "printf ok"])
        let start = Date()

        let failures = await withTaskGroup(of: String?.self, returning: [String].self) { group in
            for _ in 0..<16 {
                group.addTask {
                    await Task.detached(priority: .utility) {
                        for _ in 0..<4 {
                            do {
                                let output = try runner.run(command)
                                if output != "ok" { return "unexpected output: \(output)" }
                            } catch {
                                return "\(error)"
                            }
                        }
                        return nil
                    }.value
                }
            }
            var collected: [String] = []
            for await failure in group {
                if let failure { collected.append(failure) }
            }
            return collected
        }

        XCTAssertTrue(failures.isEmpty, "\(failures.count) tasks failed; first: \(failures[0])")
        XCTAssertLessThan(Date().timeIntervalSince(start), 4, "64 trivial runs should finish well under the timeout")
    }
}
