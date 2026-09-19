import Foundation

public enum GitClientError: Error, LocalizedError, Sendable {
    case commandFailed(String)
    case invalidRepository(String)
    case invalidCommit(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let message): message
        case .invalidRepository(let path): "Not a readable git repository: \(path)"
        case .invalidCommit(let sha): "Invalid commit identifier: \(sha)"
        }
    }
}

public protocol GitProcessRunning: Sendable {
    func run(_ command: GitCommand) throws -> String
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}

public struct GitProcessRunner: GitProcessRunning, Sendable {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 30) {
        self.timeout = timeout
    }

    public func run(_ command: GitCommand) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputData = DataBox()
        let errorData = DataBox()
        let group = DispatchGroup()

        func attach(_ handle: FileHandle, into sink: @escaping @Sendable (Data) -> Void) {
            group.enter()
            handle.readabilityHandler = { fh in
                let chunk = fh.availableData
                if chunk.isEmpty {
                    fh.readabilityHandler = nil
                    group.leave()
                } else {
                    sink(chunk)
                }
            }
        }

        attach(outputPipe.fileHandleForReading) { chunk in
            outputData.append(chunk)
        }
        attach(errorPipe.fileHandleForReading) { chunk in
            errorData.append(chunk)
        }

        // Exit is observed via terminationHandler, which Foundation invokes on its own queue.
        // Do NOT wait via waitUntilExit() on a Dispatch worker: it spins a run loop on a shared
        // pool thread, loses wakeups when many repos refresh at once, and each miss parks that
        // thread forever until the pool is exhausted and every later run times out.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            group.leave(); group.leave()
            throw error
        }

        // Bounded wait so a stalled child (dead mount, inherited pipes) can't pin the caller forever.
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            process.terminate()
            throw GitClientError.commandFailed("git command timed out after \(Int(timeout))s")
        }
        group.wait()

        // Lossy decode: one non-UTF-8 filename or commit subject must not blank the whole output.
        let output = String(decoding: outputData.snapshot(), as: UTF8.self)
        let error = String(decoding: errorData.snapshot(), as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw GitClientError.commandFailed(error.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return output
    }
}

public struct GitClient: @unchecked Sendable {
    private let runner: GitProcessRunning
    private let fileManager: FileManager
    private let maxUntrackedBytes: UInt64

    public init(
        runner: GitProcessRunning = GitProcessRunner(),
        fileManager: FileManager = .default,
        maxUntrackedBytes: UInt64 = 1_000_000
    ) {
        self.runner = runner
        self.fileManager = fileManager
        self.maxUntrackedBytes = maxUntrackedBytes
    }

    public func summarize(_ repository: RepositoryConfig, branch: BranchInfo? = nil) throws -> RepoDiffSummary {
        guard fileManager.fileExists(atPath: repository.path) else {
            throw GitClientError.invalidRepository(repository.path)
        }

        let staged = try runner.run(GitCommandFactory.command(for: .stagedNumstat, repositoryPath: repository.path))
        let unstaged = try runner.run(GitCommandFactory.command(for: .unstagedNumstat, repositoryPath: repository.path))
        let status = try runner.run(GitCommandFactory.command(for: .porcelainStatus, repositoryPath: repository.path))

        let statuses = GitStatusParser.parsePorcelainV1Z(status)
        let untrackedStats = statuses
            .filter { $0.value.unstagedStatus == .untracked }
            .reduce(into: [String: FileLineStat]()) { result, entry in
                result[entry.key] = statForUntrackedFile(repositoryPath: repository.path, relativePath: entry.key)
            }

        return RepoDiffBuilder.build(
            repository: repository,
            stagedStats: GitNumstatParser.parse(staged),
            unstagedStats: GitNumstatParser.parse(unstaged),
            statuses: statuses,
            untrackedStats: untrackedStats,
            branch: branch
        )
    }

    /// Run `git worktree list --porcelain` from `parentPath` and parse the output.
    public func discoverWorktrees(parentPath: String) throws -> [WorktreeEntry] {
        guard fileManager.fileExists(atPath: parentPath) else {
            throw GitClientError.invalidRepository(parentPath)
        }
        let output = try runner.run(GitCommandFactory.command(for: .worktreeListPorcelain, repositoryPath: parentPath))
        return GitWorktreeParser.parse(output)
    }

    public func validateRepository(path: String) throws {
        guard fileManager.fileExists(atPath: path) else {
            throw GitClientError.invalidRepository(path)
        }

        do {
            let output = try runner.run(GitCommandFactory.command(for: .isInsideWorkTree, repositoryPath: path))
            guard output.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
                throw GitClientError.invalidRepository(path)
            }
        } catch {
            throw GitClientError.invalidRepository(path)
        }
    }

    public func recentCommits(_ repository: RepositoryConfig, limit: Int? = nil) throws -> [RecentCommitSummary] {
        guard fileManager.fileExists(atPath: repository.path) else {
            throw GitClientError.invalidRepository(repository.path)
        }

        do {
            _ = try runner.run(GitCommandFactory.command(for: .hasHead, repositoryPath: repository.path))
        } catch GitClientError.commandFailed {
            return []
        }

        let resolvedLimit = RepositoryConfig.clampedRecentCommitLimit(limit ?? repository.recentCommitLimit)
        let output = try runner.run(
            GitCommandFactory.recentCommits(repositoryPath: repository.path, limit: resolvedLimit)
        )
        var commits = GitRecentCommitParser.parse(output)
        guard !commits.isEmpty else { return [] }

        let upstream: String
        do {
            upstream = try runner
                .run(GitCommandFactory.command(for: .upstreamName, repositoryPath: repository.path))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch GitClientError.commandFailed {
            return commits
        }
        guard !upstream.isEmpty else { return commits }

        let localOnlyOutput = try runner.run(
            GitCommandFactory.commitsNotOnUpstream(
                repositoryPath: repository.path,
                upstream: upstream,
                limit: resolvedLimit
            )
        )
        let localOnly = Set(localOnlyOutput.split(whereSeparator: \.isWhitespace).map(String.init))

        for index in commits.indices {
            commits[index].publicationStatus = localOnly.contains(commits[index].sha)
                ? .localOnly(upstream)
                : .onUpstream(upstream)
        }
        return commits
    }

    public func commitDetails(_ repository: RepositoryConfig, sha: String) throws -> [HistoricalChangedFile] {
        guard fileManager.fileExists(atPath: repository.path) else {
            throw GitClientError.invalidRepository(repository.path)
        }
        guard Self.isFullObjectID(sha) else {
            throw GitClientError.invalidCommit(sha)
        }

        let names = try runner.run(
            GitCommandFactory.commitNameStatus(repositoryPath: repository.path, sha: sha)
        )
        let numstat = try runner.run(
            GitCommandFactory.commitNumstat(repositoryPath: repository.path, sha: sha)
        )
        let stats = GitNumstatParser.parse(numstat)

        return GitCommitNameStatusParser.parse(names).map { entry in
            let stat = stats[entry.path] ?? FileLineStat(
                addedLines: 0,
                removedLines: 0,
                isBinary: false
            )
            return HistoricalChangedFile(
                path: entry.path,
                previousPath: entry.previousPath,
                status: entry.status,
                addedLines: stat.addedLines,
                removedLines: stat.removedLines,
                isBinary: stat.isBinary
            )
        }
    }

    private static func isFullObjectID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.allSatisfy(\.isHexDigit)
    }

    private func statForUntrackedFile(repositoryPath: String, relativePath: String) -> FileLineStat {
        let url = URL(fileURLWithPath: repositoryPath).appendingPathComponent(relativePath)

        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let type = attributes?[.type] as? FileAttributeType

        // Git stores a symlink's target path as its content: one line, never binary.
        if type == .typeSymbolicLink {
            return FileLineStat(addedLines: 1, removedLines: 0, isBinary: false)
        }

        guard let attributes, type == .typeRegular else {
            return FileLineStat(addedLines: 0, removedLines: 0, isBinary: true)
        }

        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard fileSize <= maxUntrackedBytes else {
            return FileLineStat(addedLines: 0, removedLines: 0, isBinary: false, isTooLarge: true)
        }

        // Unreadable is not binary; report no lines rather than a misleading label.
        guard let data = try? Data(contentsOf: url) else {
            return FileLineStat(addedLines: 0, removedLines: 0, isBinary: false)
        }

        if data.contains(0) {
            return FileLineStat(addedLines: 0, removedLines: 0, isBinary: true)
        }

        let lineCount = countLines(in: data)
        return FileLineStat(addedLines: lineCount, removedLines: 0, isBinary: false)
    }

    private func countLines(in data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        let newline = UInt8(ascii: "\n")
        let newlineCount = data.reduce(0) { $0 + ($1 == newline ? 1 : 0) }
        return data.last == newline ? newlineCount : newlineCount + 1
    }
}
