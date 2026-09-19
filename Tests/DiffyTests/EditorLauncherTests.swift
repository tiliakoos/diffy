import Foundation
import XCTest
@testable import Diffy

final class EditorLauncherTests: XCTestCase {
    private let fileURL = URL(fileURLWithPath: "/tmp/repo/$(touch /tmp/pwned)")
    private let repoURL = URL(fileURLWithPath: "/tmp/repo")

    func testUnquotedPlaceholderExpandsEscaped() {
        let expanded = EditorLauncher.expandedCommand("open {path}", fileURL: fileURL, repositoryURL: repoURL)
        XCTAssertEqual(expanded, "open '/tmp/repo/$(touch /tmp/pwned)'")
    }

    func testDoubleQuotedPlaceholderIsRejected() {
        XCTAssertNil(EditorLauncher.expandedCommand("code \"{path}\"", fileURL: fileURL, repositoryURL: repoURL))
    }

    func testSingleQuotedPlaceholderIsRejected() {
        XCTAssertNil(EditorLauncher.expandedCommand("echo '{repo}'", fileURL: fileURL, repositoryURL: repoURL))
    }

    func testEscapedQuoteDoesNotOpenQuotedSection() {
        // \" outside quotes is a literal quote character; the placeholder itself is unquoted.
        XCTAssertNotNil(EditorLauncher.expandedCommand("echo \\\"{path}\\\"", fileURL: fileURL, repositoryURL: repoURL))
    }

    func testSingleQuoteInPathStaysEscaped() {
        let oddFile = URL(fileURLWithPath: "/tmp/repo/it's.swift")
        let expanded = EditorLauncher.expandedCommand("open {path}", fileURL: oddFile, repositoryURL: repoURL)
        XCTAssertEqual(expanded, "open '/tmp/repo/it'\\''s.swift'")
    }
}
