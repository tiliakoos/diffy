import Combine
import DiffyCore
import Foundation

enum GroupRemovalMode {
    case dissolveIntoStandalone
    case deleteRepos
}

enum RepositoryDestination {
    case existingGroup(UUID)
    case newGroup
}

struct CommitHistoryState: Equatable {
    var requestID: UUID
    var limit: Int
    var commits: [RecentCommitSummary]
    var isLoading: Bool
    var errorMessage: String?
}

struct CommitDetailsState: Equatable {
    var requestID: UUID
    var sha: String
    var files: [HistoricalChangedFile]
    var isLoading: Bool
    var errorMessage: String?
}

@MainActor
final class DiffyStore: ObservableObject {
    @Published private(set) var groups: [RepositoryGroup] = []
    @Published private(set) var repositories: [RepositoryConfig] = []
    @Published private(set) var summaries: [UUID: RepoDiffSummary] = [:]
    @Published private(set) var commitHistories: [UUID: CommitHistoryState] = [:]
    @Published private(set) var commitDetails: [UUID: CommitDetailsState] = [:]
    /// Latest porcelain output keyed by parent (user-added) repo UUID. Transient — not persisted.
    /// Read by the UI via `isGitMainWorktree(repositoryID:)`.
    @Published private(set) var lastWorktreeEntries: [UUID: [WorktreeEntry]] = [:]
    @Published private(set) var lastAddError: String?
    @Published private(set) var lastPersistenceError: String?
    @Published private(set) var lastWorktreeRemovalError: String?

    private let gitClient: GitClient
    private let worktreeMutator = GitWorktreeMutator()
    private var watchers: [UUID: RepositoryWatcher] = [:]
    private var refreshRequestIDs: [UUID: UUID] = [:]
    private var pollingTask: Task<Void, Never>?
    private let storageURL: URL

    init(storageURL: URL? = nil, gitClient: GitClient = GitClient()) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        self.gitClient = gitClient
    }

    func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            lastPersistenceError = nil
            return
        }

        let state: StoredState
        do {
            state = try StoredStateMigration.decode(Data(contentsOf: storageURL))
        } catch {
            lastPersistenceError = "Failed to load saved repositories: \(error.localizedDescription)"
            return
        }
        lastPersistenceError = nil
        groups = state.groups
        repositories = state.repositories
        if normalizeRepositoryRows() {
            save()
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let state = StoredState(groups: groups, repositories: repositories)
            let data = try JSONEncoder().encode(state)
            try data.write(to: storageURL, options: .atomic)
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = "Failed to save repositories: \(error.localizedDescription)"
        }
    }

    func start() {
        if normalizeRepositoryRows() {
            save()
        }
        rebuildWatchers()
        refreshAll()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    break
                }
                self?.refreshAll()
            }
        }
    }

    /// Defensive cleanup for auto-managed rows whose parent relationship or path identity
    /// is already invalid in persisted state.
    private func normalizeRepositoryRows() -> Bool {
        let byID = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0) })
        var idsToRemove = Set<UUID>()

        for repo in repositories where repo.isAutoManaged {
            guard let parentID = repo.parentRepositoryID,
                  let parent = byID[parentID],
                  !parent.isAutoManaged
            else {
                idsToRemove.insert(repo.id)
                continue
            }
        }

        let duplicateCandidates = repositories.filter { !idsToRemove.contains($0.id) }
        idsToRemove.formUnion(WorktreeInventoryPolicy.duplicateRepositoryIDsToRemove(repositories: duplicateCandidates))

        guard !idsToRemove.isEmpty else { return false }
        for id in idsToRemove {
            tearDownRow(id: id)
            lastWorktreeEntries.removeValue(forKey: id)
        }
        return true
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        refreshRequestIDs.removeAll()
        watchers.values.forEach { $0.stop() }
        watchers.removeAll()
    }

    // MARK: - Repositories

    func addRepository(path: String, destination: RepositoryDestination) {
        let url = URL(fileURLWithPath: path)
        let canonical = canonicalPath(url.path)

        if let existing = repositories.first(where: { canonicalPath($0.path) == canonical }) {
            if existing.isAutoManaged {
                guard let groupID = destinationGroupID(for: destination, name: url.lastPathComponent) else { return }
                promoteAutoManagedRepository(
                    existing,
                    toPath: url.path,
                    displayName: url.lastPathComponent,
                    groupID: groupID
                )
            } else {
                lastAddError = "This path is already tracked."
            }
            return
        }

        do {
            try gitClient.validateRepository(path: url.path)
        } catch {
            lastAddError = error.localizedDescription
            return
        }

        guard let groupID = destinationGroupID(for: destination, name: url.lastPathComponent) else { return }

        let config = RepositoryConfig(
            displayName: url.lastPathComponent,
            path: url.path,
            groupID: groupID
        )
        repositories.append(config)
        lastAddError = nil
        save()
        seedRow(config)
    }

    private func destinationGroupID(for destination: RepositoryDestination, name: String) -> UUID? {
        switch destination {
        case .existingGroup(let id):
            guard groups.contains(where: { $0.id == id }) else {
                lastAddError = "The selected group no longer exists."
                return nil
            }
            return id
        case .newGroup:
            let group = RepositoryGroup(name: name)
            groups.append(group)
            return group.id
        }
    }

    private func promoteAutoManagedRepository(
        _ repository: RepositoryConfig,
        toPath path: String,
        displayName: String,
        groupID: UUID
    ) {
        guard let index = repositories.firstIndex(where: { $0.id == repository.id }) else { return }
        let oldParentID = repositories[index].parentRepositoryID

        repositories[index].displayName = displayName
        repositories[index].path = path
        repositories[index].groupID = groupID
        repositories[index].parentRepositoryID = nil
        repositories[index].isAutoManaged = false
        updateSummaryRepository(repositories[index])

        for childIndex in repositories.indices where repositories[childIndex].parentRepositoryID == repository.id {
            repositories[childIndex].groupID = groupID
            updateSummaryRepository(repositories[childIndex])
        }

        restartWatcher(for: repositories[index])
        lastAddError = nil
        save()
        refresh(repositoryID: repository.id)
        if let oldParentID {
            refresh(repositoryID: oldParentID)
        }
    }

    func clearAddError() {
        lastAddError = nil
    }

    func removeRepository(_ repository: RepositoryConfig) {
        let cascadeIDs: [UUID] = [repository.id]
            + repositories.filter { $0.parentRepositoryID == repository.id }.map(\.id)
        for id in cascadeIDs {
            tearDownRow(id: id)
        }
        if repository.parentRepositoryID == nil {
            lastWorktreeEntries.removeValue(forKey: repository.id)
        }
        save()
    }

    func updateEditor(for repository: RepositoryConfig, editor: EditorPreference) {
        guard let index = repositories.firstIndex(where: { $0.id == repository.id }) else { return }
        guard repositories[index].editor != editor else { return }
        repositories[index].editor = editor
        updateSummaryRepository(repositories[index])
        save()
    }

    func setHidden(_ repositoryID: UUID, isHidden: Bool) {
        guard let index = repositories.firstIndex(where: { $0.id == repositoryID }) else { return }
        guard repositories[index].isHidden != isHidden else { return }
        repositories[index].isHidden = isHidden
        updateSummaryRepository(repositories[index])
        save()
    }

    func updateRecentCommitLimit(for repositoryID: UUID, limit: Int) {
        guard let index = repositories.firstIndex(where: { $0.id == repositoryID }) else { return }
        let clamped = RepositoryConfig.clampedRecentCommitLimit(limit)
        guard repositories[index].recentCommitLimit != clamped else { return }

        repositories[index].recentCommitLimit = clamped
        updateSummaryRepository(repositories[index])
        save()

        if commitHistories[repositoryID] != nil {
            loadRecentCommits(repositoryID: repositoryID, force: true)
        }
    }

    func loadRecentCommits(repositoryID: UUID, force: Bool = false) {
        guard let repository = repositories.first(where: { $0.id == repositoryID }) else { return }
        let limit = repository.recentCommitLimit
        let existing = commitHistories[repositoryID]

        if !force,
           let existing,
           existing.limit == limit,
           existing.isLoading || existing.errorMessage == nil {
            return
        }

        let requestID = UUID()
        commitHistories[repositoryID] = CommitHistoryState(
            requestID: requestID,
            limit: limit,
            commits: existing?.limit == limit ? existing?.commits ?? [] : [],
            isLoading: true,
            errorMessage: nil
        )

        Task.detached(priority: .utility) { [gitClient] in
            do {
                let commits = try gitClient.recentCommits(repository, limit: limit)
                await MainActor.run {
                    guard let current = self.repositories.first(where: { $0.id == repositoryID }),
                          current.recentCommitLimit == limit,
                          self.commitHistories[repositoryID]?.limit == limit,
                          self.commitHistories[repositoryID]?.requestID == requestID
                    else { return }

                    self.commitHistories[repositoryID] = CommitHistoryState(
                        requestID: requestID,
                        limit: limit,
                        commits: commits,
                        isLoading: false,
                        errorMessage: nil
                    )
                    let visibleSHAs = Set(commits.map(\.sha))
                    if let details = self.commitDetails[repositoryID], !visibleSHAs.contains(details.sha) {
                        self.commitDetails.removeValue(forKey: repositoryID)
                    }
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    guard self.repositories.contains(where: { $0.id == repositoryID }),
                          self.commitHistories[repositoryID]?.limit == limit,
                          self.commitHistories[repositoryID]?.requestID == requestID
                    else { return }
                    self.commitHistories[repositoryID]?.isLoading = false
                    self.commitHistories[repositoryID]?.errorMessage = message
                }
            }
        }
    }

    func loadCommitDetails(repositoryID: UUID, sha: String) {
        guard let repository = repositories.first(where: { $0.id == repositoryID }),
              let requestedLimit = commitHistories[repositoryID]?.limit,
              commitHistories[repositoryID]?.commits.contains(where: { $0.sha == sha }) == true
        else { return }

        if let existing = commitDetails[repositoryID],
           existing.sha == sha,
           existing.isLoading || existing.errorMessage == nil {
            return
        }

        let requestID = UUID()
        commitDetails[repositoryID] = CommitDetailsState(
            requestID: requestID, sha: sha, files: [], isLoading: true, errorMessage: nil
        )

        Task.detached(priority: .utility) { [gitClient] in
            do {
                let files = try gitClient.commitDetails(repository, sha: sha)
                await MainActor.run {
                    guard self.repositories.contains(where: { $0.id == repositoryID }),
                          self.commitHistories[repositoryID]?.limit == requestedLimit,
                          self.commitHistories[repositoryID]?.commits.contains(where: { $0.sha == sha }) == true,
                          self.commitDetails[repositoryID]?.requestID == requestID
                    else { return }
                    self.commitDetails[repositoryID] = CommitDetailsState(
                        requestID: requestID, sha: sha, files: files, isLoading: false, errorMessage: nil
                    )
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    guard self.repositories.contains(where: { $0.id == repositoryID }),
                          self.commitHistories[repositoryID]?.limit == requestedLimit,
                          self.commitHistories[repositoryID]?.commits.contains(where: { $0.sha == sha }) == true,
                          self.commitDetails[repositoryID]?.requestID == requestID
                    else { return }
                    self.commitDetails[repositoryID] = CommitDetailsState(
                        requestID: requestID, sha: sha, files: [], isLoading: false, errorMessage: message
                    )
                }
            }
        }
    }

    func refreshLoadedRecentCommits(groupID: UUID) {
        for repository in repositories where repository.groupID == groupID && commitHistories[repository.id] != nil {
            loadRecentCommits(repositoryID: repository.id, force: true)
        }
    }

    func moveRepository(_ repositoryID: UUID, toGroup groupID: UUID) {
        guard let index = repositories.firstIndex(where: { $0.id == repositoryID }) else { return }
        guard groups.contains(where: { $0.id == groupID }) else { return }
        guard repositories[index].groupID != groupID else { return }
        guard repositories[index].parentRepositoryID == nil else { return }

        repositories[index].groupID = groupID
        updateSummaryRepository(repositories[index])

        for childIndex in repositories.indices where repositories[childIndex].parentRepositoryID == repositoryID {
            repositories[childIndex].groupID = groupID
            updateSummaryRepository(repositories[childIndex])
        }

        save()
    }

    // MARK: - Groups

    @discardableResult
    func addGroup(name: String = "", diffColors: DiffColors = .default) -> RepositoryGroup {
        let group = RepositoryGroup(name: name, diffColors: diffColors)
        groups.append(group)
        save()
        return group
    }

    func renameGroup(_ groupID: UUID, to newName: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        guard groups[index].name != newName else { return }
        groups[index].name = newName
        save()
    }

    func updateGroupColors(_ groupID: UUID, diffColors: DiffColors) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        guard groups[index].diffColors != diffColors else { return }
        groups[index].diffColors = diffColors
        save()
    }

    func updateGroupBadgeLabel(_ groupID: UUID, badgeLabel: BadgeLabel?) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        guard groups[index].badgeLabel != badgeLabel else { return }
        groups[index].badgeLabel = badgeLabel
        save()
    }

    func setGroupHidden(_ groupID: UUID, isHidden: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        guard groups[index].isHidden != isHidden else { return }
        groups[index].isHidden = isHidden
        save()
    }

    func reorderGroups(_ orderedIDs: [UUID]) {
        let byID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        var reordered: [RepositoryGroup] = []
        reordered.reserveCapacity(groups.count)
        for id in orderedIDs {
            if let group = byID[id] {
                reordered.append(group)
            }
        }
        for group in groups where !orderedIDs.contains(group.id) {
            reordered.append(group)
        }
        guard reordered.count == groups.count else { return }
        groups = reordered
        save()
    }

    func removeGroup(_ groupID: UUID, mode: GroupRemovalMode) {
        let parents = repositories.filter { $0.groupID == groupID && $0.parentRepositoryID == nil }

        switch mode {
        case .dissolveIntoStandalone:
            for parent in parents {
                let newGroup = RepositoryGroup(name: parent.displayName)
                groups.append(newGroup)
                if let index = repositories.firstIndex(where: { $0.id == parent.id }) {
                    repositories[index].groupID = newGroup.id
                    updateSummaryRepository(repositories[index])
                }
                for childIndex in repositories.indices where repositories[childIndex].parentRepositoryID == parent.id {
                    repositories[childIndex].groupID = newGroup.id
                    updateSummaryRepository(repositories[childIndex])
                }
            }
        case .deleteRepos:
            // Two-pass to avoid mutating `repositories` while iterating it.
            var idsToRemove: [UUID] = []
            for parent in parents {
                idsToRemove.append(parent.id)
                idsToRemove.append(contentsOf: repositories.filter { $0.parentRepositoryID == parent.id }.map(\.id))
            }
            for id in idsToRemove {
                tearDownRow(id: id)
            }
            for parent in parents {
                lastWorktreeEntries.removeValue(forKey: parent.id)
            }
        }
        groups.removeAll { $0.id == groupID }
        save()
    }

    // MARK: - Worktree-specific public surface

    /// True when the auto-managed row is the git-main worktree of its repo family
    /// (which `git worktree remove` cannot remove). Detected from the first entry in
    /// the parent's most-recent porcelain output.
    func isGitMainWorktree(repositoryID: UUID) -> Bool {
        guard let repo = repositories.first(where: { $0.id == repositoryID }),
              let parentID = repo.parentRepositoryID,
              let entries = lastWorktreeEntries[parentID],
              let first = entries.first
        else { return false }
        return canonicalPath(first.path) == canonicalPath(repo.path)
    }

    /// Returns rows in a group with each parent immediately followed by its auto-managed children.
    /// When `includeHidden` is true, hidden parents (and their children) sink to the bottom.
    /// When false, hidden rows are filtered out.
    func orderedRepositories(in groupID: UUID, includeHidden: Bool) -> [RepositoryConfig] {
        let inGroup = repositories.filter { $0.groupID == groupID }
        let parents = inGroup.filter { $0.parentRepositoryID == nil }
        let orderedParents: [RepositoryConfig]
        if includeHidden {
            orderedParents = parents.filter { !$0.isHidden } + parents.filter { $0.isHidden }
        } else {
            orderedParents = parents
        }

        var result: [RepositoryConfig] = []
        result.reserveCapacity(inGroup.count)
        for parent in orderedParents {
            if includeHidden || !parent.isHidden {
                result.append(parent)
            }
            let children = repositories.filter { $0.parentRepositoryID == parent.id }
            result.append(contentsOf: includeHidden ? children : children.filter { !$0.isHidden })
        }
        return result
    }

    /// Sums added/removed lines across a group's non-hidden repositories.
    func aggregateVisibleTotals(groupID: UUID) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for repository in repositories where repository.groupID == groupID && !repository.isHidden {
            if let summary = summaries[repository.id] {
                added += summary.addedLines
                removed += summary.removedLines
            }
        }
        return (added, removed)
    }

    func clearWorktreeRemovalError() {
        lastWorktreeRemovalError = nil
    }

    func removeWorktree(repositoryID: UUID) {
        guard let child = repositories.first(where: { $0.id == repositoryID }) else { return }
        guard let parentID = child.parentRepositoryID,
              let parent = repositories.first(where: { $0.id == parentID }) else { return }

        let childPath = child.path
        let parentPath = parent.path
        let mutator = self.worktreeMutator

        Task.detached(priority: .userInitiated) {
            do {
                try mutator.remove(parentPath: parentPath, worktreePath: childPath)
                await MainActor.run {
                    self.lastWorktreeRemovalError = nil
                    // FSEvents on the parent's .git/worktrees/ will drive natural reconcile; trigger
                    // an immediate refresh too so the row drops without waiting on the debounce.
                    self.refresh(repositoryID: parentID)
                }
            } catch {
                await MainActor.run {
                    self.lastWorktreeRemovalError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Refresh plumbing

    func refreshAll() {
        repositories.forEach(refresh)
    }

    func refresh(repositoryID: UUID) {
        guard let repository = repositories.first(where: { $0.id == repositoryID }) else { return }
        refresh(repository)
    }

    private func refresh(_ repository: RepositoryConfig) {
        let requestID = UUID()
        refreshRequestIDs[repository.id] = requestID

        let isParentRefresh = (repository.parentRepositoryID == nil)
        let parentPath: String
        let parentID: UUID

        if let pid = repository.parentRepositoryID,
           let parent = repositories.first(where: { $0.id == pid }) {
            parentPath = parent.path
            parentID = parent.id
        } else {
            parentPath = repository.path
            parentID = repository.id
        }

        // Children that have a cached parent porcelain output skip their own porcelain call
        // (saves N+1 git subprocesses per parent refresh wave). Branch info may be up to one
        // refresh cycle stale, which is acceptable.
        let cachedBranch: BranchInfo?
        if !isParentRefresh, let cached = lastWorktreeEntries[parentID] {
            let canonicalSelf = canonicalPath(repository.path)
            cachedBranch = cached.first(where: { canonicalPath($0.path) == canonicalSelf })?.branch
        } else {
            cachedBranch = nil
        }
        let useCachedBranchOnly = !isParentRefresh && cachedBranch != nil

        Task.detached(priority: .utility) { [gitClient] in
            do {
                let branch: BranchInfo?
                var entries: [WorktreeEntry]? = nil

                if useCachedBranchOnly {
                    branch = cachedBranch
                } else {
                    let fetched = try gitClient.discoverWorktrees(parentPath: parentPath)
                    entries = fetched
                    let canonicalSelf = canonicalPath(repository.path)
                    branch = fetched.first(where: { canonicalPath($0.path) == canonicalSelf })?.branch
                }
                let summary = try gitClient.summarize(repository, branch: branch)

                await MainActor.run {
                    guard self.refreshRequestIDs[repository.id] == requestID,
                          self.repositories.contains(where: { $0.id == repository.id })
                    else { return }
                    if self.summaries[repository.id] != summary {
                        self.summaries[repository.id] = summary
                    }
                    if isParentRefresh, let entries {
                        if self.lastWorktreeEntries[parentID] != entries {
                            self.lastWorktreeEntries[parentID] = entries
                        }
                        self.reconcileChildren(parentID: parentID, entries: entries)
                    }
                }
            } catch {
                let result = RepoDiffSummary.empty(for: repository).withError(error.localizedDescription)
                await MainActor.run {
                    guard self.refreshRequestIDs[repository.id] == requestID,
                          self.repositories.contains(where: { $0.id == repository.id })
                    else { return }
                    if self.summaries[repository.id] != result {
                        self.summaries[repository.id] = result
                    }
                }
            }
        }
    }

    /// Add/remove auto-managed child rows so they mirror the family-owner policy.
    private func reconcileChildren(parentID: UUID, entries: [WorktreeEntry]) {
        guard let parent = repositories.first(where: { $0.id == parentID }) else { return }

        let expected = WorktreeInventoryPolicy.desiredAutoManagedChildren(
            parent: parent,
            repositories: repositories,
            entries: entries
        )
        let expectedCanonicalSet = Set(expected.map(\.canonicalPath))

        let currentChildren = repositories.filter { $0.parentRepositoryID == parentID }
        let duplicateChildIDs = Set(WorktreeInventoryPolicy.duplicateRepositoryIDsToRemove(repositories: currentChildren))
        var currentByCanonical: [String: RepositoryConfig] = [:]
        for child in currentChildren where !duplicateChildIDs.contains(child.id) {
            currentByCanonical[canonicalPath(child.path)] = child
        }
        let currentCanonicalSet = Set(currentByCanonical.keys)

        var mutated = false

        for id in duplicateChildIDs {
            tearDownRow(id: id)
            mutated = true
        }

        let gone = currentCanonicalSet.subtracting(expectedCanonicalSet)
        if !gone.isEmpty {
            for canonical in gone {
                guard let child = currentByCanonical[canonical] else { continue }
                tearDownRow(id: child.id)
            }
            mutated = true
        }

        for candidate in expected {
            let canonical = candidate.canonicalPath
            let entry = candidate.entry

            if let child = currentByCanonical[canonical],
               let index = repositories.firstIndex(where: { $0.id == child.id }) {
                let displayName = worktreeDisplayName(for: entry)
                let shouldRestartWatcher = repositories[index].path != entry.path
                if repositories[index].displayName != displayName
                    || repositories[index].path != entry.path
                    || repositories[index].groupID != parent.groupID
                    || repositories[index].parentRepositoryID != parent.id
                    || repositories[index].isAutoManaged != true {
                    repositories[index].displayName = displayName
                    repositories[index].path = entry.path
                    repositories[index].groupID = parent.groupID
                    repositories[index].parentRepositoryID = parent.id
                    repositories[index].isAutoManaged = true
                    updateSummaryRepository(repositories[index])
                    if shouldRestartWatcher {
                        restartWatcher(for: repositories[index])
                    }
                    mutated = true
                }
                continue
            }

            if let index = repositories.firstIndex(where: { repo in
                repo.isAutoManaged && canonicalPath(repo.path) == canonical
            }) {
                repositories[index].displayName = worktreeDisplayName(for: entry)
                repositories[index].path = entry.path
                repositories[index].groupID = parent.groupID
                repositories[index].parentRepositoryID = parent.id
                repositories[index].isAutoManaged = true
                updateSummaryRepository(repositories[index])
                restartWatcher(for: repositories[index])
                mutated = true
                continue
            }

            let child = RepositoryConfig(
                displayName: worktreeDisplayName(for: entry),
                path: entry.path,
                groupID: parent.groupID,
                parentRepositoryID: parent.id,
                isAutoManaged: true
            )
            repositories.append(child)
            seedRow(child)
            mutated = true
        }

        if mutated {
            save()
        }
    }

    private func worktreeDisplayName(for entry: WorktreeEntry) -> String {
        switch entry.branch {
        case .branch(let name): name
        default: URL(fileURLWithPath: entry.path).lastPathComponent
        }
    }

    // MARK: - Row lifecycle helpers

    /// Install a freshly-created `RepositoryConfig` that's already in `repositories`:
    /// seed an empty summary, start a watcher, and trigger a first refresh.
    private func seedRow(_ config: RepositoryConfig) {
        summaries[config.id] = .empty(for: config)
        startWatcher(for: config)
        refresh(config)
    }

    /// Remove every trace of a row from `repositories`, `summaries`, and `watchers`.
    /// Idempotent — missing entries are no-ops.
    private func tearDownRow(id: UUID) {
        repositories.removeAll { $0.id == id }
        summaries.removeValue(forKey: id)
        commitHistories.removeValue(forKey: id)
        commitDetails.removeValue(forKey: id)
        refreshRequestIDs.removeValue(forKey: id)
        watchers[id]?.stop()
        watchers.removeValue(forKey: id)
    }

    private func rebuildWatchers() {
        watchers.values.forEach { $0.stop() }
        watchers.removeAll()
        repositories.forEach(startWatcher)
    }

    private func startWatcher(for repository: RepositoryConfig) {
        let gitdir = resolveLinkedWorktreeGitdir(at: repository.path)

        let watcher = RepositoryWatcher(repositoryPath: repository.path, gitdirPath: gitdir) { [weak self] in
            Task { @MainActor in
                self?.refresh(repositoryID: repository.id)
            }
        }

        if watcher.start() {
            watchers[repository.id] = watcher
        }
    }

    private func restartWatcher(for repository: RepositoryConfig) {
        watchers[repository.id]?.stop()
        watchers.removeValue(forKey: repository.id)
        startWatcher(for: repository)
    }

    private static func defaultStorageURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diffy", isDirectory: true)
            .appendingPathComponent("repositories.json")
    }

    private func updateSummaryRepository(_ repository: RepositoryConfig) {
        if var summary = summaries[repository.id] {
            summary.repository = repository
            summaries[repository.id] = summary
        }
    }
}

private extension RepoDiffSummary {
    func withError(_ message: String) -> RepoDiffSummary {
        var copy = self
        copy.errorMessage = message
        return copy
    }
}
