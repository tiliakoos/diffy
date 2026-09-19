import AppKit
import DiffyCore
import Foundation

enum EditorLauncher {
    static func open(file: ChangedFileSummary, in repository: RepositoryConfig, onError: (String) -> Void) {
        guard file.isOpenableFromWorkingTree else { return }
        open(relativePath: file.path, in: repository, onError: onError)
    }

    static func openCurrentVersion(path: String, in repository: RepositoryConfig, onError: (String) -> Void) {
        guard currentVersionExists(path: path, in: repository) else { return }
        open(relativePath: path, in: repository, onError: onError)
    }

    static func currentVersionExists(path: String, in repository: RepositoryConfig) -> Bool {
        FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: repository.path).appendingPathComponent(path).path
        )
    }

    private static func open(relativePath: String, in repository: RepositoryConfig, onError: (String) -> Void) {
        let fileURL = URL(fileURLWithPath: repository.path).appendingPathComponent(relativePath)

        switch repository.editor {
        case .systemDefault:
            NSWorkspace.shared.open(fileURL)
        case .appBundleIdentifier(let bundleIdentifier):
            runOpen(arguments: ["-b", bundleIdentifier, fileURL.path], onError: onError)
        case .command(let command):
            runShell(command: command, fileURL: fileURL, repositoryURL: URL(fileURLWithPath: repository.path), onError: onError)
        }
    }

    private static func runOpen(arguments: [String], onError: (String) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            onError("Couldn't launch the editor: \(error.localizedDescription)")
        }
    }

    private static func runShell(command: String, fileURL: URL, repositoryURL: URL, onError: (String) -> Void) {
        guard let expanded = expandedCommand(command, fileURL: fileURL, repositoryURL: repositoryURL) else {
            onError("Custom editor command rejected: {path} and {repo} must appear unquoted.")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", expanded]
        do {
            try process.run()
        } catch {
            onError("Couldn't run the custom editor command: \(error.localizedDescription)")
        }
    }

    /// Placeholder escaping is only valid outside quotes — a quoted placeholder neutralizes
    /// the escaping and reopens command injection — so reject those templates outright.
    static func expandedCommand(_ command: String, fileURL: URL, repositoryURL: URL) -> String? {
        for placeholder in ["{path}", "{repo}"] {
            var searchStart = command.startIndex
            while let range = command.range(of: placeholder, range: searchStart..<command.endIndex) {
                if isInsideQuotes(command, upTo: range.lowerBound) { return nil }
                searchStart = range.upperBound
            }
        }
        return command
            .replacingOccurrences(of: "{path}", with: shellEscape(fileURL.path))
            .replacingOccurrences(of: "{repo}", with: shellEscape(repositoryURL.path))
    }

    private static func isInsideQuotes(_ command: String, upTo limit: String.Index) -> Bool {
        var inSingle = false
        var inDouble = false
        var index = command.startIndex
        while index < limit {
            let character = command[index]
            let next = command.index(after: index)
            if character == "\\", next < limit {
                index = command.index(after: next)
                continue
            }
            if character == "'", !inDouble {
                inSingle.toggle()
            } else if character == "\"", !inSingle {
                inDouble.toggle()
            }
            index = next
        }
        return inSingle || inDouble
    }

    private static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
