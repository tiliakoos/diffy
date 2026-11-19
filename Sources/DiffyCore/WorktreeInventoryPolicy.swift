import Foundation

public struct WorktreeChildCandidate: Equatable, Sendable {
    public var canonicalPath: String
    public var entry: WorktreeEntry

    public init(canonicalPath: String, entry: WorktreeEntry) {
        self.canonicalPath = canonicalPath
        self.entry = entry
    }
}

public enum WorktreeInventoryPolicy {
    /// The user-added row that lists a repository's unadded worktrees under itself: of the
    /// family's user-added rows, the one git lists first. That is the main worktree when the
    /// user added it. Git's order, not the display order, so reordering rows never moves
    /// worktrees to a different parent.
    public static func familyOwnerID(repositories: [RepositoryConfig], entries: [WorktreeEntry]) -> UUID? {
        let members = familyMembers(repositories: repositories, entries: entries)
        for entry in entries {
            let path = canonicalPath(entry.path)
            if let owner = members.first(where: { canonicalPath($0.path) == path }) {
                return owner.id
            }
        }
        return nil
    }

    public static func desiredAutoManagedChildren(
        parent: RepositoryConfig,
        repositories: [RepositoryConfig],
        entries: [WorktreeEntry]
    ) -> [WorktreeChildCandidate] {
        guard familyOwnerID(repositories: repositories, entries: entries) == parent.id else { return [] }

        let userManagedPaths = Set(
            repositories
                .filter { !$0.isAutoManaged }
                .map { canonicalPath($0.path) }
        )
        let dismissed = familyMembers(repositories: repositories, entries: entries).flatMap(\.dismissedWorktrees)

        var seen = Set<String>()
        var result: [WorktreeChildCandidate] = []
        result.reserveCapacity(entries.count)

        for entry in entries {
            if entry.isPrunable { continue }
            if case .bare = entry.branch { continue }

            let canonical = canonicalPath(entry.path)
            if userManagedPaths.contains(canonical) { continue }
            if dismissed.contains(where: { $0.matches(entry) }) { continue }
            guard seen.insert(canonical).inserted else { continue }

            result.append(WorktreeChildCandidate(canonicalPath: canonical, entry: entry))
        }

        return result
    }

    /// Dismissals that no longer hide anything: the worktree is gone, or its path now has a
    /// different branch checked out (which shows it again).
    public static func staleDismissals(of repository: RepositoryConfig, entries: [WorktreeEntry]) -> [DismissedWorktree] {
        repository.dismissedWorktrees.filter { dismissed in
            !entries.contains(where: { dismissed.matches($0) })
        }
    }

    /// User-added rows whose paths are worktrees of this family.
    private static func familyMembers(repositories: [RepositoryConfig], entries: [WorktreeEntry]) -> [RepositoryConfig] {
        let worktreePaths = Set(entries.map { canonicalPath($0.path) })
        return repositories.filter { repo in
            !repo.isAutoManaged && worktreePaths.contains(canonicalPath(repo.path))
        }
    }

    public static func duplicateRepositoryIDsToRemove(repositories: [RepositoryConfig]) -> [UUID] {
        var buckets: [String: [RepositoryConfig]] = [:]
        for repo in repositories {
            buckets[canonicalPath(repo.path), default: []].append(repo)
        }

        var remove = Set<UUID>()
        for bucket in buckets.values where bucket.count > 1 {
            let keep = bucket.first { !$0.isAutoManaged } ?? bucket[0]
            for repo in bucket where repo.id != keep.id {
                remove.insert(repo.id)
            }
        }

        return repositories.map(\.id).filter { remove.contains($0) }
    }
}
