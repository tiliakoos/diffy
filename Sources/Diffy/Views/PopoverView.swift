import AppKit
import DiffyCore
import SwiftUI

/// The menu-bar popover: a header with the group's totals, a Changes / History control, then a
/// compact list. Anything with nothing to report takes one line; changed repositories list their
/// files underneath; worktrees hang off their parent. 340 pt wide like Apple's own menu extras.
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
    /// Open worktree folds, keyed by segment and parent.
    @State private var openFolds: Set<String> = []
    /// The one repository whose commits are open in a group's History.
    @State private var openHistory: UUID?
    @State private var copiedKey: String?
    @State private var pendingWorktreeRemoval: UUID?
    @State private var hoveredRow: UUID?

    // Drag to reorder (see `PlatterReorder`).
    @State private var reorder: PlatterReorder?
    @State private var reorderCancelled = false
    @State private var platterFrames: [UUID: CGRect] = [:]
    @State private var scrollMetrics = ScrollMetrics()
    @State private var scrollPosition = ScrollPosition()
    @State private var autoScroll = 0

    /// Space between top-level repositories. Worktrees inside a family sit flush.
    private static let blockSpacing: CGFloat = 4
    private static let plattersSpace = "popoverPlatters"
    private static let viewportSpace = "popoverViewport"
    /// How close to the top or bottom edge a drag starts scrolling the list.
    private static let autoScrollEdge: CGFloat = 28

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
                .frame(width: 170)
                .padding(.top, 6)
                .padding(.bottom, 4)
            }
            content
            Divider()
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
            MenuRow(title: "Open Diffy", shortcut: "⌘O", action: onOpenWindow)
                .keyboardShortcut("o", modifiers: .command)
        }
        .padding(.bottom, 6)
        .frame(width: 340)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand {
            if reorder != nil {
                cancelReorder()
            } else {
                onClose()
            }
        }
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

    private var topLevel: [RepositoryConfig] {
        repositories.filter { $0.parentRepositoryID == nil }
    }

    private func children(of id: UUID) -> [RepositoryConfig] {
        repositories.filter { $0.parentRepositoryID == id }
    }

    private var singleRepository: RepositoryConfig? {
        repositories.count == 1 ? repositories[0] : nil
    }

    private var colors: DiffColors {
        group?.diffColors ?? .default
    }

    private var lastChange: Date? {
        repositories.compactMap { store.summaries[$0.id]?.refreshedAt }.max()
    }

    /// A repository's files split for display. A conflicted file shows up as both staged and
    /// unstaged in git's output; it is listed once, under Conflicts.
    private struct FileSplit {
        var conflicts: [ChangedFileSummary] = []
        var staged: [ChangedFileSummary] = []
        var unstaged: [ChangedFileSummary] = []

        var all: [ChangedFileSummary] { conflicts + staged + unstaged }
        var count: Int { conflicts.count + staged.count + unstaged.count }
    }

    private func split(_ summary: RepoDiffSummary) -> FileSplit {
        var result = FileSplit()
        for file in summary.stagedFiles + summary.unstagedFiles where file.displayStatus == "!" {
            if let index = result.conflicts.firstIndex(where: { $0.path == file.path }) {
                let existing = result.conflicts[index]
                if file.addedLines + file.removedLines > existing.addedLines + existing.removedLines {
                    result.conflicts[index] = file
                }
            } else {
                result.conflicts.append(file)
            }
        }
        result.staged = summary.stagedFiles.filter { $0.displayStatus != "!" }
        result.unstaged = summary.unstagedFiles.filter { $0.displayStatus != "!" }
        return result
    }

    private func isClean(_ repository: RepositoryConfig) -> Bool {
        guard let summary = store.summaries[repository.id], summary.errorMessage == nil else { return false }
        return summary.stagedFiles.isEmpty && summary.unstagedFiles.isEmpty
    }

    private func isAllPushed(_ repository: RepositoryConfig) -> Bool {
        guard let commits = store.commitHistories[repository.id]?.commits, !commits.isEmpty else { return false }
        return commits.allSatisfy { if case .onUpstream = $0.publicationStatus { true } else { false } }
    }

    /// Worktrees in your order, with a trailing run of two or more quiet ones split off to fold.
    /// Only the tail folds, so nothing ever changes position.
    private func foldSplit(_ kids: [RepositoryConfig], isQuiet: (RepositoryConfig) -> Bool) -> (shown: [RepositoryConfig], tail: [RepositoryConfig]) {
        var cut = kids.count
        while cut > 0, isQuiet(kids[cut - 1]) {
            cut -= 1
        }
        let tail = Array(kids[cut...])
        return tail.count >= 2 ? (Array(kids[..<cut]), tail) : (kids, [])
    }

    private func foldKey(_ parentID: UUID) -> String {
        "\(segment == .changes ? "changes" : "history"):\(parentID.uuidString)"
    }

    private func visibleChildren(of parentID: UUID) -> [RepositoryConfig] {
        let (shown, tail) = foldSplit(children(of: parentID), isQuiet: isClean)
        return openFolds.contains(foldKey(parentID)) ? shown + tail : shown
    }

    /// The rows on screen in the Changes list, each top-level row followed by its visible worktrees.
    private var visibleRows: [RepositoryConfig] {
        topLevel.flatMap { [$0] + visibleChildren(of: $0.id) }
    }

    // MARK: - Header

    private var header: some View {
        let totals = store.aggregateVisibleTotals(groupID: groupID)
        let single = singleRepository
        let readable = repositories.compactMap { store.summaries[$0.id] }.filter { $0.errorMessage == nil }
        let files = readable.flatMap { split($0).all }
        let errorCount = repositories.filter { store.summaries[$0.id]?.errorMessage != nil }.count
        let groupName = group?.name ?? ""

        var meta: [(text: String, isWarning: Bool)] = []
        if let single {
            if let branch = branchLabel(store.summaries[single.id]?.branch) {
                meta.append((branch, false))
            }
            if !files.isEmpty {
                meta.append((files.count == 1 ? "1 file" : "\(files.count.formatted(.number)) files", false))
            }
        } else if !repositories.isEmpty {
            let count = topLevel.count
            meta.append((count == 1 ? "1 repository" : "\(count) repositories", false))
            if errorCount > 0 {
                meta.append(("\(errorCount) can\u{2019}t be read", true))
            }
        }
        if let lastChange, Date().timeIntervalSince(lastChange) >= 60 {
            meta.append(("Changed \(compactAge(since: lastChange)) ago", false))
        }

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                if let group, single == nil {
                    GroupTile(group: group, index: groupIndex, size: 20)
                }
                Text(single?.displayName ?? (groupName.isEmpty ? "Diffy" : groupName))
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if repositories.isEmpty || errorCount == repositories.count {
                    EmptyView()
                } else if totals.added + totals.removed > 0 {
                    HStack(spacing: 9) {
                        if totals.added > 0 {
                            Text("+\(totals.added.formatted(.number))").foregroundStyle(colors.additionColor)
                        }
                        if totals.removed > 0 {
                            Text("\u{2212}\(totals.removed.formatted(.number))").foregroundStyle(colors.removalColor)
                        }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .fixedSize()
                } else if !files.isEmpty {
                    let binary = files.allSatisfy(\.isBinary)
                    Text(files.count == 1 ? (binary ? "1 binary file" : "1 file") : "\(files.count) \(binary ? "binary files" : "files")")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                } else if readable.count == repositories.count - errorCount {
                    Label("Clean", systemImage: "checkmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            if !meta.isEmpty {
                meta.enumerated().reduce(Text("")) { line, part in
                    line
                        + (part.offset > 0 ? Text("  \u{00B7}  ").foregroundStyle(.tertiary) : Text(""))
                        + Text(part.element.text).foregroundStyle(part.element.isWarning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                }
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 2)
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
        .padding(.top, 4)
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
            let fades = scrollMetrics.content - scrollMetrics.offset - scrollMetrics.viewport > 4
            ScrollView {
                VStack(alignment: .leading, spacing: Self.blockSpacing) {
                    switch segment {
                    case .changes: changes
                    case .history: history
                    }
                }
                .coordinateSpace(.named(Self.plattersSpace))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.never)
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(
                    offset: geometry.contentOffset.y,
                    viewport: geometry.containerSize.height,
                    content: geometry.contentSize.height
                )
            } action: { _, metrics in
                scrollMetrics = metrics
            }
            .coordinateSpace(.named(Self.viewportSpace))
            .frame(maxHeight: 520)
            .fixedSize(horizontal: false, vertical: true)
            // A list that runs past the bottom fades out there, so it reads as "more below".
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, fades ? .clear : .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 24)
                }
            }
            .task(id: autoScroll) {
                await runAutoScroll()
            }
        }
    }

    // MARK: - Changes

    @ViewBuilder
    private var changes: some View {
        if let single = singleRepository {
            if let summary = store.summaries[single.id] {
                if let error = summary.errorMessage {
                    errorBox(error, in: single)
                } else if summary.stagedFiles.isEmpty, summary.unstagedFiles.isEmpty {
                    cleanLine(for: single)
                } else {
                    let files = split(summary)
                    fileSections(files, limit: shownLimit(for: single), in: single)
                    pagingRow(for: single, total: files.count)
                }
            } else {
                checking
            }
        } else {
            ForEach(topLevel) { repository in
                reorderable(repository, isChild: false) {
                    family(repository)
                }
            }
        }
    }

    /// One top-level repository: its row, its files, then its worktrees on a guide line.
    private func family(_ repository: RepositoryConfig) -> some View {
        let kids = children(of: repository.id)
        let (shown, tail) = foldSplit(kids, isQuiet: isClean)
        let key = foldKey(repository.id)
        let isOpen = openFolds.contains(key)
        let hasBody = !kids.isEmpty || !isClean(repository) && store.summaries[repository.id]?.errorMessage == nil
        return VStack(alignment: .leading, spacing: 0) {
            repositoryRow(repository)
            repositoryFiles(repository)
            if !kids.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(isOpen ? shown + tail : shown) { child in
                        reorderable(child, isChild: true) {
                            VStack(alignment: .leading, spacing: 0) {
                                repositoryRow(child)
                                repositoryFiles(child)
                            }
                        }
                    }
                    if !tail.isEmpty {
                        DisclosureRow(
                            title: isOpen ? "Hide \(tail.count) clean worktrees" : "\(tail.count) clean worktrees",
                            isExpanded: isOpen
                        ) {
                            toggleFold(key)
                        }
                    }
                }
                .modifier(WorktreeGuide())
            }
        }
        .padding(.bottom, hasBody ? 6 : 0)
    }

    /// A repository on one line: name, branch, then its counts, a ✓, or what went wrong. The
    /// drag grip and ⋯ appear on hover over the end of the dim text, so the counts never move.
    private func repositoryRow(_ repository: RepositoryConfig) -> some View {
        let summary = store.summaries[repository.id]
        let error = summary?.errorMessage
        let showsActions = reorder == nil ? hoveredRow == repository.id : reorder?.id == repository.id
        let reorderable = canReorder(repository)
        return HStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(repository.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(error == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if error == nil, let detail = branchLabel(distinctBranch(summary?.branch, for: repository)) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                if showsActions {
                    HoverActions {
                        if reorderable {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .frame(width: 16, height: 20)
                                .help("Drag to reorder")
                                .accessibilityHidden(true)
                        }
                        repositoryMenu(repository)
                    }
                }
            }
            repositoryTrailing(repository, summary: summary)
        }
        .frame(height: 26)
        .padding(.horizontal, 8)
        .help(error ?? "")
        .onHover { hovering in
            if hovering {
                hoveredRow = repository.id
            } else if hoveredRow == repository.id {
                hoveredRow = nil
            }
        }
        .contextMenu { repositoryMenuItems(repository) }
        .modifier(ReorderHandle(
            isEnabled: reorderable,
            isDragging: reorder?.id == repository.id,
            gesture: reorderGesture(for: repository.id),
            onHover: { _ in }
        ))
    }

    @ViewBuilder
    private func repositoryTrailing(_ repository: RepositoryConfig, summary: RepoDiffSummary?) -> some View {
        if let error = summary?.errorMessage {
            Label(errorTitle(for: error, in: repository), systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize()
        } else if let summary {
            let files = split(summary).all
            if files.isEmpty {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("No changes")
            } else if summary.addedLines + summary.removedLines == 0, !files.allSatisfy(\.isBinary) {
                Text(files.count == 1 ? "1 file" : "\(files.count) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            } else {
                FileCounts(
                    added: summary.addedLines,
                    removed: summary.removedLines,
                    isBinary: files.allSatisfy(\.isBinary),
                    hidesZero: true,
                    colors: colors
                )
            }
        } else {
            ProgressView().controlSize(.mini)
        }
    }

    /// Files under a repository in a group: the four that matter most (conflicts first, then the
    /// largest) until asked for more, then pages of 50 in Conflicts / Staged / Unstaged.
    @ViewBuilder
    private func repositoryFiles(_ repository: RepositoryConfig) -> some View {
        if let summary = store.summaries[repository.id], summary.errorMessage == nil {
            let files = split(summary)
            if files.count > 0 {
                VStack(alignment: .leading, spacing: 0) {
                    if let limit = shownFileLimits[repository.id] {
                        fileSections(files, limit: limit, in: repository)
                        pagingRow(for: repository, total: files.count)
                    } else {
                        let largest = (files.staged + files.unstaged)
                            .sorted { $0.addedLines + $0.removedLines > $1.addedLines + $1.removedLines }
                        ForEach(Array((files.conflicts + largest).prefix(Self.previewFileCount))) { file in
                            fileRow(file, in: repository)
                        }
                        if files.count > Self.previewFileCount {
                            let more = files.count - Self.previewFileCount
                            DisclosureRow(title: more == 1 ? "1 more file" : "\(more.formatted(.number)) more files", isExpanded: false) {
                                // Not animated: the popover resizes to the content's ideal size, and an
                                // animated layout re-sizes it every frame, which stutters and jumps.
                                shownFileLimits[repository.id] = Self.pageSize
                            }
                        }
                    }
                }
                .padding(.leading, 12)
            }
        }
    }

    /// Conflicts, Staged and Unstaged, never more rows in total than `limit`.
    @ViewBuilder
    private func fileSections(_ files: FileSplit, limit: Int, in repository: RepositoryConfig) -> some View {
        let sections = [("Conflicts", files.conflicts, true), ("Staged", files.staged, false), ("Unstaged", files.unstaged, false)]
        let shown = sections.reduce(into: (left: limit, out: [(String, [ChangedFileSummary], Bool)]())) { state, section in
            guard !section.1.isEmpty, state.left > 0 else { return }
            state.out.append((section.0, Array(section.1.prefix(state.left)), section.2))
            state.left -= section.1.count
        }.out
        ForEach(shown, id: \.0) { title, rows, isWarning in
            SectionTitle(title: title, isWarning: isWarning)
            ForEach(rows) { file in
                fileRow(file, in: repository)
            }
        }
    }

    /// A single repository shows a page of 50; a group's repositories start with four.
    private func shownLimit(for repository: RepositoryConfig) -> Int {
        shownFileLimits[repository.id] ?? (singleRepository == nil ? Self.previewFileCount : Self.pageSize)
    }

    @ViewBuilder
    private func pagingRow(for repository: RepositoryConfig, total: Int) -> some View {
        let shown = min(shownLimit(for: repository), total)
        let remaining = total - shown
        let isPaged = shownFileLimits[repository.id] != nil
        if remaining > 0 || isPaged {
            HStack(spacing: 0) {
                if remaining > 0 {
                    let page = min(Self.pageSize, remaining)
                    DisclosureRow(
                        title: remaining > page ? "Show \(page) more of \(remaining.formatted(.number)) files" : "Show \(page) more files",
                        isExpanded: false
                    ) {
                        shownFileLimits[repository.id] = shown + Self.pageSize
                    }
                }
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

    /// A clean single repository: one line, plus the last commit and whether it's pushed.
    private func cleanLine(for repository: RepositoryConfig) -> some View {
        let last = store.commitHistories[repository.id]?.commits.first
        return HStack(spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nothing has changed since the last commit.")
                    .font(.callout)
                if let last {
                    let age = compactAge(since: last.committedAt)
                    HStack(spacing: 0) {
                        Text("\u{201C}\(last.subject)\u{201D}")
                            .lineLimit(1)
                            .truncationMode(.tail)
                        (Text(age == "now" ? "  \u{00B7}  just now  \u{00B7}  " : "  \u{00B7}  \(age) ago  \u{00B7}  ")
                            + publicationText(last.publicationStatus))
                            .fixedSize()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .onAppear {
            store.loadRecentCommits(repositoryID: repository.id)
        }
    }

    private func publicationText(_ status: CommitPublicationStatus) -> Text {
        switch status {
        case .localOnly: Text("not pushed").foregroundStyle(.orange)
        case .noUpstream: Text("no upstream")
        case .onUpstream: Text("pushed")
        }
    }

    private var checking: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Checking…").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    // MARK: - History

    @ViewBuilder
    private var history: some View {
        if let single = singleRepository {
            if let error = store.summaries[single.id]?.errorMessage {
                errorBox(error, in: single)
            } else {
                commitList(single)
            }
        } else {
            ForEach(topLevel) { repository in
                historyFamily(repository)
            }
        }
    }

    private func historyFamily(_ repository: RepositoryConfig) -> some View {
        let kids = children(of: repository.id)
        let (shown, tail) = foldSplit(kids, isQuiet: isAllPushed)
        let key = foldKey(repository.id)
        let isOpen = openFolds.contains(key)
        return VStack(alignment: .leading, spacing: 0) {
            historyEntry(repository)
            if !kids.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(isOpen ? shown + tail : shown) { child in
                        historyEntry(child)
                    }
                    if !tail.isEmpty {
                        DisclosureRow(
                            title: isOpen ? "Hide \(tail.count) pushed worktrees" : "\(tail.count) worktrees, all pushed",
                            isExpanded: isOpen
                        ) {
                            toggleFold(key)
                        }
                    }
                }
                .modifier(WorktreeGuide())
            }
        }
    }

    @ViewBuilder
    private func historyEntry(_ repository: RepositoryConfig) -> some View {
        HistoryRow(
            repository: repository,
            history: store.commitHistories[repository.id],
            errorTitle: store.summaries[repository.id]?.errorMessage.map { errorTitle(for: $0, in: repository) },
            isOpen: openHistory == repository.id
        ) {
            // Snaps open: only one repository's commits at a time.
            openHistory = openHistory == repository.id ? nil : repository.id
        }
        .contextMenu { repositoryMenuItems(repository) }
        .onAppear {
            store.loadRecentCommits(repositoryID: repository.id)
        }
        if openHistory == repository.id, store.summaries[repository.id]?.errorMessage == nil {
            commitList(repository)
                .padding(.leading, 14)
        }
    }

    private func commitList(_ repository: RepositoryConfig) -> some View {
        CommitList(
            store: store,
            repository: repository,
            colors: colors,
            copiedKey: copiedKey,
            onCopy: copyToPasteboard,
            onCopyPath: copyPath
        )
    }

    // MARK: - Reordering

    /// A row (or a family) that can be dragged among its siblings. Rows only move by offset while
    /// dragging; the store's order changes once, on drop. A top-level drag moves whole families,
    /// so worktrees apply an offset only when a worktree is the one being dragged.
    private func reorderable<Content: View>(_ repository: RepositoryConfig, isChild: Bool, @ViewBuilder content: () -> Content) -> some View {
        let id = repository.id
        let applies = reorder != nil && reorderMovesChildren == isChild
        let isMoving = applies && reorder?.isMoving(id) == true
        let offset = applies ? (reorder?.offset(for: id, scrollOffset: scrollMetrics.offset) ?? 0) : 0
        let tracksPointer = isMoving && reorder?.settledTranslation == nil
        return content()
            .background {
                if isMoving {
                    // Lifted: opaque so the rows sliding beneath don't show through, with a shadow.
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
                }
            }
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(Self.plattersSpace))
            } action: { frame in
                // Frames are snapshotted when a drag starts; offsets mustn't feed back into them.
                if reorder == nil {
                    platterFrames[id] = frame
                }
            }
            .offset(y: offset)
            .animation(tracksPointer ? nil : .snappy(duration: 0.2), value: offset)
            .zIndex(isMoving ? 1 : 0)
            .accessibilityAction(named: "Move Up") {
                store.moveRepository(id, by: -1, includeHidden: false)
            }
            .accessibilityAction(named: "Move Down") {
                store.moveRepository(id, by: 1, includeHidden: false)
            }
    }

    /// Whether the current drag is reordering one parent's worktrees.
    private var reorderMovesChildren: Bool {
        guard let id = reorder?.id else { return false }
        return repositories.first { $0.id == id }?.parentRepositoryID != nil
    }

    private func canReorder(_ repository: RepositoryConfig) -> Bool {
        singleRepository == nil
            && segment == .changes
            && visibleRows.filter { $0.parentRepositoryID == repository.parentRepositoryID }.count > 1
    }

    private func reorderGesture(for id: UUID) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.viewportSpace))
            .onChanged { value in
                guard !reorderCancelled else { return }
                if reorder == nil {
                    let isChild = repositories.first { $0.id == id }?.parentRepositoryID != nil
                    reorder = PlatterReorder(
                        id: id,
                        rows: visibleRows,
                        frames: platterFrames,
                        spacing: isChild ? 0 : Self.blockSpacing,
                        scrollOffset: scrollMetrics.offset
                    )
                }
                guard reorder != nil else { return }
                reorder?.pointerTranslation = value.translation.height
                let y = value.location.y
                autoScroll = y < Self.autoScrollEdge ? -1 : (y > scrollMetrics.viewport - Self.autoScrollEdge ? 1 : 0)
            }
            .onEnded { _ in
                autoScroll = 0
                if reorderCancelled {
                    reorderCancelled = false
                } else {
                    finishReorder()
                }
            }
    }

    /// Glide the grabbed rows into their slot, then commit the order with no animation, so
    /// the rows already drawn in their new places don't move again. Folded worktrees keep their
    /// place at the end: the store reorders only the siblings it's given.
    private func finishReorder() {
        guard var drag = reorder else { return }
        let target = drag.targetIndex(scrollOffset: scrollMetrics.offset)
        let order = target == drag.originalIndex ? nil : drag.order(droppingAt: target)
        drag.settledTranslation = drag.restingTranslation(for: target)
        withAnimation(.snappy(duration: 0.18)) {
            reorder = drag
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if let order {
                    store.reorderSiblings(order)
                }
                reorder = nil
            }
        }
    }

    /// Esc while dragging: everything slides home and the order doesn't change.
    private func cancelReorder() {
        guard var drag = reorder else { return }
        reorderCancelled = true
        autoScroll = 0
        drag.settledTranslation = 0
        withAnimation(.snappy(duration: 0.18)) {
            reorder = drag
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                reorder = nil
            }
        }
    }

    /// While a drag holds the pointer near the top or bottom edge, scroll that way.
    private func runAutoScroll() async {
        guard autoScroll != 0 else { return }
        while !Task.isCancelled, reorder != nil {
            let maxOffset = max(scrollMetrics.content - scrollMetrics.viewport, 0)
            let next = min(max(scrollMetrics.offset + CGFloat(autoScroll) * 6, 0), maxOffset)
            if next != scrollMetrics.offset {
                scrollPosition.scrollTo(y: next)
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    private func toggleFold(_ key: String) {
        // Snaps, no animation: the popover sizes to its content.
        if openFolds.contains(key) {
            openFolds.remove(key)
        } else {
            openFolds.insert(key)
        }
    }

    // MARK: - Repository menu

    /// A new group rebuilds every status item, including the one hosting this popover, and
    /// `StatusItemManager` updates synchronously. Close first and move on the next main-queue
    /// turn so the teardown never runs inside this view's own button action.
    private func trackSeparately(_ repositoryID: UUID, destination: RepositoryDestination) {
        onClose()
        DispatchQueue.main.async { [store] in
            store.trackWorktreeSeparately(repositoryID: repositoryID, destination: destination)
        }
    }

    /// The same items behind ⋯ and on right-click.
    @ViewBuilder
    private func repositoryMenuItems(_ repository: RepositoryConfig) -> some View {
        let summary = store.summaries[repository.id]
        Button("Reveal in Finder") { reveal(URL(fileURLWithPath: repository.path)) }
        Divider()
        Button("Copy Path") { copySilent(repository.path) }
        if case .branch(let name)? = summary?.branch {
            Button("Copy Branch Name") { copySilent(name) }
        }
        if let error = summary?.errorMessage {
            Button("Copy Error") { copySilent(error) }
        }
        if repository.isAutoManaged {
            Divider()
            Menu("Track Separately") {
                ForEach(store.groups) { group in
                    Button(group.name.isEmpty ? "Unnamed group" : group.name) {
                        trackSeparately(repository.id, destination: .existingGroup(group.id))
                    }
                }
                Divider()
                Button("New Group") {
                    trackSeparately(repository.id, destination: .newGroup)
                }
            }
            Button("Stop Tracking") {
                store.dismissWorktree(repositoryID: repository.id)
            }
            if !store.isGitMainWorktree(repositoryID: repository.id) {
                Button("Remove Worktree…", role: .destructive) {
                    pendingWorktreeRemoval = repository.id
                }
            }
        }
    }

    private func repositoryMenu(_ repository: RepositoryConfig) -> some View {
        Menu {
            repositoryMenuItems(repository)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("More actions for \(repository.displayName)")
    }

    // MARK: - States

    /// A single repository that can't be read: a plain title, git's own text underneath.
    private func errorBox(_ message: String, in repository: RepositoryConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(errorTitle(for: message, in: repository), systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    /// A plain-language title for git's most common failures; git's own text goes in the
    /// tooltip and the Copy Error menu item.
    private func errorTitle(for message: String, in repository: RepositoryConfig) -> String {
        if !FileManager.default.fileExists(atPath: repository.path) {
            return "Folder not found"
        }
        let lowered = message.lowercased()
        if lowered.contains("no such file") || lowered.contains("cannot change to") {
            return "Folder not found"
        }
        if lowered.contains("not a git repository") {
            return "Not a Git repository"
        }
        if lowered.contains("timed out") {
            return "Git timed out"
        }
        return "Can\u{2019}t read repository"
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
