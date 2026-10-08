import AppKit
import DiffyCore
import SwiftUI

/// The refreshed menu-bar popover: one header with totals, a Changes / History control, then
/// files (or commits) per repository. 340 pt wide like Apple's own menu extras.
struct PopoverView: View {
    @ObservedObject var store: DiffyStore
    let groupID: UUID
    let onOpenWindow: () -> Void
    let onClose: () -> Void

    private enum Segment: Hashable {
        case changes
        case history
    }

    @State private var segment: Segment = .changes
    @State private var shownFileLimits: [UUID: Int] = [:]
    @State private var copiedKey: String?
    @State private var pendingWorktreeRemoval: UUID?

    private static let previewFileCount = 4
    /// Rows added per "Show more". Every row on screen is laid out at once on the main thread
    /// when the popover opens or resizes, so this cap is what keeps a change with thousands of
    /// files from freezing the app.
    private static let pageSize = 50

    var body: some View {
        VStack(spacing: 0) {
            header
            if let editorError = store.lastEditorError {
                editorErrorBanner(editorError)
            }
            if !repositories.isEmpty {
                Picker("", selection: $segment) {
                    Text("Changes").tag(Segment.changes)
                    Text("History").tag(Segment.history)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
            content
            Divider()
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            MenuRow(title: "Add Repository…", action: addRepository)
            MenuRow(title: "Open Diffy", shortcut: "⌘O", action: onOpenWindow)
                .keyboardShortcut("o", modifiers: .command)
        }
        .padding(.bottom, 6)
        .frame(width: 340)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand(perform: onClose)
        .task(id: copiedKey) {
            guard let copiedKey else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, self.copiedKey == copiedKey else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                self.copiedKey = nil
            }
        }
        .confirmationDialog(
            "Remove worktree?",
            isPresented: worktreeRemovalPresented,
            titleVisibility: .visible
        ) {
            Button("Remove Worktree", role: .destructive) {
                if let id = pendingWorktreeRemoval {
                    store.clearWorktreeRemovalError()
                    store.removeWorktree(repositoryID: id)
                }
                pendingWorktreeRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                pendingWorktreeRemoval = nil
            }
        } message: {
            Text(pendingWorktreeRemoval.map(store.worktreeRemovalMessage(for:)) ?? "")
        }
    }

    // MARK: - Data

    private var group: RepositoryGroup? {
        store.groups.first { $0.id == groupID }
    }

    private var groupIndex: Int {
        store.groups.firstIndex { $0.id == groupID } ?? 0
    }

    private var repositories: [RepositoryConfig] {
        store.orderedRepositories(in: groupID, includeHidden: false)
    }

    private var singleRepository: RepositoryConfig? {
        repositories.count == 1 ? repositories[0] : nil
    }

    private var colors: DiffColors {
        group?.diffColors ?? .default
    }

    private var lastRefresh: Date? {
        repositories.compactMap { store.summaries[$0.id]?.refreshedAt }.max()
    }

    // MARK: - Header

    private var header: some View {
        let totals = store.aggregateVisibleTotals(groupID: groupID)
        let single = singleRepository
        let singleSummary = single.flatMap { store.summaries[$0.id] }
        let groupName = group?.name ?? ""
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 7) {
                    if let group, single == nil {
                        GroupTile(group: group, index: groupIndex, size: 20)
                    }
                    Text(single?.displayName ?? (groupName.isEmpty ? "Diffy" : groupName))
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                if totals.added == 0, totals.removed == 0 {
                    Text(repositories.isEmpty ? "" : "No changes")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.tertiary)
                } else {
                    HStack(spacing: 10) {
                        Text("+\(totals.added.formatted(.number))").foregroundStyle(colors.additionColor)
                        Text("\u{2212}\(totals.removed.formatted(.number))").foregroundStyle(colors.removalColor)
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                }
            }
            HStack(spacing: 10) {
                if single != nil {
                    BranchSubtitle(branch: singleSummary?.branch)
                    if let singleSummary, singleSummary.errorMessage == nil {
                        let count = singleSummary.stagedFiles.count + singleSummary.unstagedFiles.count
                        Text("^[\(count) file](inflect: true)")
                    }
                } else {
                    let repositoryCount = repositories.filter { $0.parentRepositoryID == nil }.count
                    Text("^[\(repositoryCount) repository](inflect: true)")
                }
                if let lastRefresh {
                    if Date().timeIntervalSince(lastRefresh) < 60 {
                        Text("Updated just now")
                    } else {
                        Text("Updated \(lastRefresh, style: .relative) ago")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if totals.added + totals.removed > 0 {
                RatioBar(added: totals.added, removed: totals.removed, colors: colors)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private func editorErrorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("Dismiss", action: store.clearEditorError)
                .buttonStyle(.borderless)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if group == nil {
            unavailable("Group Not Found", symbol: "questionmark.folder",
                        message: "This menu-bar item is no longer associated with a group.")
        } else if repositories.isEmpty {
            if store.repositories.contains(where: { $0.groupID == groupID }) {
                unavailable("Nothing Counted", symbol: "eye.slash",
                            message: "Every repository in this group is excluded from its totals. Turn one back on in Diffy.") {
                    Button("Open Diffy", action: onOpenWindow)
                }
            } else {
                unavailable("No Repositories", symbol: "folder.badge.plus",
                            message: "Add a repository to start tracking its changes.") {
                    Button("Add Repository…", action: addRepository)
                }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    switch segment {
                    case .changes: changes
                    case .history: history
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 520)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var changes: some View {
        if let single = singleRepository {
            if let summary = store.summaries[single.id] {
                if let error = summary.errorMessage {
                    repositoryError(error)
                } else if summary.stagedFiles.isEmpty, summary.unstagedFiles.isEmpty {
                    unavailable("Working Tree Clean", symbol: "checkmark.circle",
                                message: "Everything matches the last commit. History is one click away.")
                } else {
                    fileSections(for: summary, in: single)
                    pagingRow(for: single, total: summary.stagedFiles.count + summary.unstagedFiles.count)
                        .padding(.horizontal, 6)
                }
            } else {
                checking
            }
        } else {
            ForEach(repositories) { repository in
                Platter(indented: repository.parentRepositoryID != nil) {
                    repositoryPlatter(repository)
                }
            }
        }
    }

    @ViewBuilder
    private var history: some View {
        ForEach(repositories) { repository in
            HistorySection(
                store: store,
                repository: repository,
                useCardChrome: singleRepository == nil,
                colors: colors,
                copiedKey: copiedKey,
                onCopy: copyToPasteboard,
                onCopyPath: copyPath
            )
        }
        HistoryLegend()
    }

    private var checking: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Checking…").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    /// Staged then unstaged, never more rows in total than the repository's current limit.
    @ViewBuilder
    private func fileSections(for summary: RepoDiffSummary, in repository: RepositoryConfig) -> some View {
        let limit = shownLimit(for: repository)
        fileSection("Staged", files: summary.stagedFiles, limit: limit, in: repository)
        fileSection("Unstaged", files: summary.unstagedFiles, limit: limit - summary.stagedFiles.count, in: repository)
    }

    @ViewBuilder
    private func fileSection(_ title: String, files: [ChangedFileSummary], limit: Int, in repository: RepositoryConfig) -> some View {
        if !files.isEmpty, limit > 0 {
            SectionHeader(title: title, fileCount: files.count)
            VStack(spacing: 0) {
                ForEach(files.prefix(limit)) { file in
                    fileRow(file, in: repository)
                }
            }
            .padding(.horizontal, 6)
        }
    }

    /// A page of rows, or the four largest files while a group's platter is collapsed.
    private func shownLimit(for repository: RepositoryConfig) -> Int {
        shownFileLimits[repository.id] ?? (singleRepository == nil ? Self.previewFileCount : Self.pageSize)
    }

    @ViewBuilder
    private func pagingRow(for repository: RepositoryConfig, total: Int) -> some View {
        let shown = min(shownLimit(for: repository), total)
        let remaining = total - shown
        let isPaged = shownFileLimits[repository.id] != nil
        if remaining > 0 || isPaged {
            HStack {
                if remaining > 0 {
                    let page = min(Self.pageSize, remaining)
                    DisclosureRow(
                        title: remaining > page ? "Show \(page) more of \(remaining.formatted(.number)) files" : "Show \(page) more files",
                        isExpanded: false
                    ) {
                        // Not animated: the popover resizes to the content's ideal size, and an
                        // animated layout re-sizes it every frame, which stutters and jumps.
                        shownFileLimits[repository.id] = shown + Self.pageSize
                    }
                }
                Spacer()
                if isPaged {
                    DisclosureRow(title: "Show fewer", isExpanded: true) {
                        shownFileLimits[repository.id] = nil
                    }
                }
            }
        }
    }

    private func fileRow(_ file: ChangedFileSummary, in repository: RepositoryConfig) -> some View {
        FileRow(
            file: file,
            colors: colors,
            showsCopied: copiedKey == fileCopiedKey(file.path, in: repository),
            onOpen: { EditorLauncher.open(file: file, in: repository, onError: store.reportEditorError) },
            onReveal: { reveal(fileURL(file.path, in: repository)) },
            onCopyPath: { copyPath(file.path, repository) }
        )
    }

    // MARK: - Multi-repository platter

    @ViewBuilder
    private func repositoryPlatter(_ repository: RepositoryConfig) -> some View {
        let summary = store.summaries[repository.id]
        let files = (summary?.stagedFiles ?? []) + (summary?.unstagedFiles ?? [])

        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(repository.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if repository.isAutoManaged {
                            Label("worktree", systemImage: "arrow.turn.down.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("·").font(.caption2).foregroundStyle(.tertiary)
                        }
                        BranchSubtitle(branch: summary?.branch)
                        if !files.isEmpty {
                            Text("· ^[\(files.count) file](inflect: true)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 8)
                if let summary, summary.errorMessage == nil {
                    if files.isEmpty {
                        Label("No changes", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        FileCounts(added: summary.addedLines, removed: summary.removedLines, isBinary: false, colors: colors)
                    }
                }
                repositoryMenu(repository, branch: summary?.branch)
            }
            .padding(.horizontal, 10)

            if let error = summary?.errorMessage {
                repositoryError(error).padding(.horizontal, 2)
            } else if summary == nil {
                checking
            } else if !files.isEmpty {
                if let summary, shownFileLimits[repository.id] != nil {
                    fileSections(for: summary, in: repository)
                } else {
                    VStack(spacing: 0) {
                        ForEach(largest(files)) { file in
                            fileRow(file, in: repository)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.top, 4)
                }
                pagingRow(for: repository, total: files.count)
                    .padding(.horizontal, 2)
            }

            if store.lastWorktreeRemovalRepositoryID == repository.id, let error = store.lastWorktreeRemovalError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
            }
        }
    }

    private func largest(_ files: [ChangedFileSummary]) -> [ChangedFileSummary] {
        Array(files.sorted { $0.addedLines + $0.removedLines > $1.addedLines + $1.removedLines }.prefix(Self.previewFileCount))
    }

    private func repositoryMenu(_ repository: RepositoryConfig, branch: BranchInfo?) -> some View {
        Menu {
            Button("Reveal in Finder") { reveal(URL(fileURLWithPath: repository.path)) }
            Divider()
            Button("Copy Path") { copySilent(repository.path) }
            if case .branch(let name)? = branch {
                Button("Copy Branch Name") { copySilent(name) }
            }
            if repository.isAutoManaged, !store.isGitMainWorktree(repositoryID: repository.id) {
                Divider()
                Button("Remove Worktree…", role: .destructive) {
                    pendingWorktreeRemoval = repository.id
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More actions for \(repository.displayName)")
    }

    // MARK: - States

    private func repositoryError(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(Self.errorTitle(for: message), systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// A plain-language title for git's most common failures; git's own text stays underneath.
    private static func errorTitle(for message: String) -> String {
        let lowered = message.lowercased()
        if lowered.contains("no such file") || lowered.contains("cannot change to") {
            return "Folder Not Found"
        }
        if lowered.contains("not a git repository") {
            return "Not a Git Repository"
        }
        if lowered.contains("timed out") {
            return "Git Timed Out"
        }
        return "Can't Read Repository"
    }

    private func unavailable<Actions: View>(
        _ title: String,
        symbol: String,
        message: String,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            actions()
        }
        .padding(.vertical, 6)
    }

    // MARK: - Actions

    private var worktreeRemovalPresented: Binding<Bool> {
        Binding {
            pendingWorktreeRemoval != nil
        } set: { newValue in
            if !newValue { pendingWorktreeRemoval = nil }
        }
    }

    private func addRepository() {
        RepositoryPicker.chooseRepository(groups: store.groups, preselectedGroupID: groupID) { url, destination in
            store.addRepository(path: url.path, destination: destination)
        }
    }

    private func fileURL(_ relativePath: String, in repository: RepositoryConfig) -> URL {
        URL(fileURLWithPath: repository.path).appendingPathComponent(relativePath)
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copyPath(_ relativePath: String, _ repository: RepositoryConfig) {
        copyToPasteboard(fileURL(relativePath, in: repository).path, key: fileCopiedKey(relativePath, in: repository))
    }

    private func copyToPasteboard(_ text: String, key: String) {
        copySilent(text)
        withAnimation(.easeOut(duration: 0.15)) {
            copiedKey = key
        }
    }

    private func copySilent(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
