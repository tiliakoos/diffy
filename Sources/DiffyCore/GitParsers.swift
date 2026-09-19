import Foundation

public enum GitRecentCommitParser {
    public static func parse(_ output: String) -> [RecentCommitSummary] {
        let fields = output.split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)
        var commits: [RecentCommitSummary] = []
        var index = 0

        while index + 3 < fields.count {
            let sha = fields[index]
            let shortSHA = fields[index + 1]
            let subject = fields[index + 2]
            let timestamp = fields[index + 3]
            index += 4

            guard !sha.isEmpty, let seconds = TimeInterval(timestamp) else { continue }
            commits.append(
                RecentCommitSummary(
                    sha: sha,
                    shortSHA: shortSHA,
                    subject: subject,
                    committedAt: Date(timeIntervalSince1970: seconds)
                )
            )
        }

        return commits
    }
}

public enum GitCommitNameStatusParser {
    public static func parse(_ output: String) -> [GitNameStatusEntry] {
        let fields = output.split(separator: "\u{0}", omittingEmptySubsequences: true).map(String.init)
        var entries: [GitNameStatusEntry] = []
        var index = 0

        while index < fields.count {
            let code = fields[index]
            index += 1
            guard index < fields.count else { break }
            guard let status = status(for: code) else {
                index += 1
                continue
            }

            if status == .renamed || status == .copied {
                guard index + 1 < fields.count else { break }
                entries.append(
                    GitNameStatusEntry(path: fields[index + 1], previousPath: fields[index], status: status)
                )
                index += 2
            } else {
                entries.append(GitNameStatusEntry(path: fields[index], status: status))
                index += 1
            }
        }

        return entries
    }

    private static func status(for code: String) -> GitChangeStatus? {
        switch code.first {
        case "M", "T": .modified
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        default: nil
        }
    }
}

public enum GitNumstatParser {
    /// Parses `git diff --numstat -z` output. Records are NUL-terminated;
    /// renames take the form `<added>\t<removed>\t\0<oldpath>\0<newpath>\0`,
    /// normal records take `<added>\t<removed>\t<path>\0`.
    public static func parse(_ output: String) -> [String: FileLineStat] {
        var stats: [String: FileLineStat] = [:]
        var index = output.startIndex

        while index < output.endIndex {
            guard let added = consume(output, from: &index, until: "\t"),
                  let removed = consume(output, from: &index, until: "\t"),
                  index < output.endIndex else { break }

            let path: Substring?
            if output[index] == "\u{0}" {
                index = output.index(after: index)
                _ = consume(output, from: &index, until: "\u{0}")  // discard old path
                path = consume(output, from: &index, until: "\u{0}")
            } else {
                path = consume(output, from: &index, until: "\u{0}")
            }
            guard let path else { break }

            let isBinary = added == "-" || removed == "-"
            let stat = FileLineStat(
                addedLines: Int(added) ?? 0,
                removedLines: Int(removed) ?? 0,
                isBinary: isBinary
            )
            let key = String(path)
            // Unmerged paths appear twice mid-conflict (combined-diff artifact); merge, not last-wins.
            if let existing = stats[key] {
                stats[key] = FileLineStat(
                    addedLines: existing.addedLines + stat.addedLines,
                    removedLines: existing.removedLines + stat.removedLines,
                    isBinary: existing.isBinary || stat.isBinary
                )
            } else {
                stats[key] = stat
            }
        }

        return stats
    }

    private static func consume(_ output: String, from index: inout String.Index, until terminator: Character) -> Substring? {
        guard let end = output[index...].firstIndex(of: terminator) else { return nil }
        let value = output[index..<end]
        index = output.index(after: end)
        return value
    }
}

public enum GitStatusParser {
    private static let conflictPairs: Set<String> = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]

    public static func parsePorcelainV1Z(_ output: String) -> [String: GitPathStatus] {
        var statuses: [String: GitPathStatus] = [:]
        let records = output.split(separator: "\u{0}", omittingEmptySubsequences: true).map(String.init)
        var index = 0

        while index < records.count {
            let record = records[index]
            guard record.count >= 4 else {
                index += 1
                continue
            }

            let x = record[record.startIndex]
            let y = record[record.index(after: record.startIndex)]
            let pair = String([x, y])
            let pathStart = record.index(record.startIndex, offsetBy: 3)
            let path = String(record[pathStart...])

            if pair == "??" {
                statuses[path] = GitPathStatus(stagedStatus: nil, unstagedStatus: .untracked)
            } else if conflictPairs.contains(pair) {
                statuses[path] = GitPathStatus(stagedStatus: .conflicted, unstagedStatus: .conflicted)
            } else {
                statuses[path] = GitPathStatus(stagedStatus: status(for: x), unstagedStatus: status(for: y))
            }

            if x == "R" || x == "C" {
                index += 1
            }
            index += 1
        }

        return statuses
    }

    private static func status(for character: Character) -> GitChangeStatus? {
        switch character {
        case "M": .modified
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        default: nil
        }
    }
}
