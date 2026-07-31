import AppKit
import DiffyCore
import SwiftUI

struct PopoverContentView: View {
    @ObservedObject var store: DiffyStore
    let groupID: UUID
    let onOpenWindow: () -> Void
    let onClose: () -> Void

    @State private var contentHeight: CGFloat = 0
    @State private var copiedKey: String?
    private let bodyCap: CGFloat = 520

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 420)
        .onExitCommand(perform: onClose)
        .task(id: copiedKey) {
            guard let copiedKey else { return }

            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, self.copiedKey == copiedKey else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                self.copiedKey = nil
            }
        }
    }

    private var group: RepositoryGroup? {
        store.groups.first { $0.id == groupID }
    }

    private var orderedGroupRepos: [RepositoryConfig] {
        store.orderedRepositories(in: groupID, includeHidden: false)
    }

    private var headerColors: DiffColors {
        group?.diffColors ?? .default
    }

    private var headerTitle: String {
        if let group, !group.name.isEmpty {
            return group.name
        }
        return "Diffy"
    }

    private var header: some View {
        let totals = store.aggregateVisibleTotals(groupID: groupID)
        return HStack(alignment: .firstTextBaseline) {
            Text(headerTitle)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            HStack(spacing: 4) {
                Text("+\(totals.added)")
                    .foregroundStyle(AppColor.swiftUIColor(hex: headerColors.additionHex))
                Text("/")
                    .foregroundStyle(.secondary)
                Text("-\(totals.removed)")
                    .foregroundStyle(AppColor.swiftUIColor(hex: headerColors.removalHex))
            }
            .font(.system(.callout, design: .monospaced).weight(.medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if group == nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("Group not found")
                    .font(.subheadline.weight(.semibold))
                Text("This menu-bar item is no longer associated with a group.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(14)
        } else if orderedGroupRepos.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("No visible repositories")
                    .font(.subheadline.weight(.semibold))
                Text("Add a repository or unhide one of this group's repositories from the main window.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(14)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(orderedGroupRepos) { repository in
                        RepoBlock(
                            store: store,
                            repository: repository,
                            groupColors: headerColors,
                            useCardChrome: orderedGroupRepos.count > 1,
                            copiedKey: copiedKey,
                            onCopyPath: copyPath,
                            onCopyCommit: copyToPasteboard
                        )
                            .padding(.leading, repository.parentRepositoryID == nil ? 0 : 16)
                    }
                }
                .padding(12)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { newHeight in
                    contentHeight = newHeight
                }
            }
            .frame(height: contentHeight == 0 ? nil : min(contentHeight, bodyCap))
        }
    }

    private var footer: some View {
        HStack {
            Button {
                RepositoryPicker.chooseRepository { url in
                    store.addRepository(path: url.path, destination: .newGroup)
                }
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add Repository")

            Spacer()

            Button("See all groups") {
                onOpenWindow()
            }
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func copyPath(_ relativePath: String, in repository: RepositoryConfig) {
        let path = URL(fileURLWithPath: repository.path).appendingPathComponent(relativePath).path
        copyToPasteboard(path, key: "file:\(repository.id.uuidString):\(relativePath)")
    }

    private func copyToPasteboard(_ text: String, key: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) {
            copiedKey = key
        }
    }
}

private struct RepoBlock: View {
    @ObservedObject var store: DiffyStore
    let repository: RepositoryConfig
    let groupColors: DiffColors
    let useCardChrome: Bool
    let copiedKey: String?
    let onCopyPath: (String, RepositoryConfig) -> Void
    let onCopyCommit: (String, String) -> Void

    @State private var isHistoryExpanded = false
    @State private var expandedCommitSHA: String?

    @AppStorage(GlassPrefs.modeKey) private var appearanceMode: AppearanceMode = .standard

    private var summary: RepoDiffSummary? {
        store.summaries[repository.id]
    }

    private func fileCopiedKey(for path: String) -> String {
        "file:\(repository.id.uuidString):\(path)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(repository.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    BranchSubtitle(branch: summary?.branch)
                }
                Spacer(minLength: 8)
                if let summary {
                    HStack(spacing: 2) {
                        Text("+\(summary.addedLines)")
                            .foregroundStyle(AppColor.swiftUIColor(hex: groupColors.additionHex))
                        Text("-\(summary.removedLines)")
                            .foregroundStyle(AppColor.swiftUIColor(hex: groupColors.removalHex))
                    }
                    .font(.system(.caption, design: .monospaced))
                }
            }

            if let summary {
                if let error = summary.errorMessage {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                section(title: "Staged", files: summary.stagedFiles)
                section(title: "Unstaged", files: summary.unstagedFiles)
                if summary.stagedFiles.isEmpty && summary.unstagedFiles.isEmpty && summary.errorMessage == nil {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.green)
                        Text("Working tree clean")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }

            recentCommitsSection
        }
        .padding(10)
        .background {
            if useCardChrome {
                if appearanceMode == .appleGlass {
                    GlassBackground(shape: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                }
            }
        }
    }

    @ViewBuilder
    private func section(title: String, files: [ChangedFileSummary]) -> some View {
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(height: 0.5)
                }
                VStack(spacing: 0) {
                    ForEach(files) { file in
                        ZStack {
                            Button {
                                EditorLauncher.open(file: file, in: repository)
                            } label: {
                                CompactFileRow(
                                    file: file,
                                    diffColors: groupColors,
                                    showsCopied: copiedKey == fileCopiedKey(for: file.path)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(!file.isOpenableFromWorkingTree)
                            .help(file.isOpenableFromWorkingTree ? "Open file" : "Deleted files cannot be opened from the working tree.")
                        }
                        .contextMenu {
                            Button("Copy Full Path") {
                                onCopyPath(file.path, repository)
                            }
                        }
                    }
                }
            }
        }
    }

    private var history: CommitHistoryState? {
        store.commitHistories[repository.id]
    }

    @ViewBuilder
    private var recentCommitsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    isHistoryExpanded.toggle()
                    if isHistoryExpanded {
                        store.loadRecentCommits(repositoryID: repository.id)
                    } else {
                        expandedCommitSHA = nil
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isHistoryExpanded ? 90 : 0))
                    Text("Recent commits")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(height: 0.5)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isHistoryExpanded {
                Group {
                    if history?.isLoading == true && history?.commits.isEmpty == true {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    } else if let error = history?.errorMessage, history?.commits.isEmpty == true {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    } else if history?.commits.isEmpty == true {
                        Text("No commits yet")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else if let commits = history?.commits {
                        VStack(spacing: 1) {
                            ForEach(commits) { commit in
                                commitRow(commit)
                            }
                        }
                        if history?.isLoading == true {
                            ProgressView()
                                .controlSize(.mini)
                                .frame(maxWidth: .infinity)
                        } else if let error = history?.errorMessage {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
    }

    private func commitRow(_ commit: RecentCommitSummary) -> some View {
        let commitCopiedKey = "commit:\(repository.id.uuidString):\(commit.sha)"
        return VStack(alignment: .leading, spacing: 2) {
            CommitRow(
                commit: commit,
                isExpanded: expandedCommitSHA == commit.sha,
                showsCopied: copiedKey == commitCopiedKey,
                onToggle: {
                    withAnimation(.easeOut(duration: 0.18)) {
                        if expandedCommitSHA == commit.sha {
                            expandedCommitSHA = nil
                        } else {
                            expandedCommitSHA = commit.sha
                            store.loadCommitDetails(repositoryID: repository.id, sha: commit.sha)
                        }
                    }
                },
                onCopySHA: { onCopyCommit(commit.sha, commitCopiedKey) },
                onCopySubject: { onCopyCommit(commit.subject, commitCopiedKey) }
            )

            if expandedCommitSHA == commit.sha {
                commitDetails(for: commit.sha)
                    .padding(.leading, 14)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func commitDetails(for sha: String) -> some View {
        if let details = store.commitDetails[repository.id], details.sha == sha {
            if details.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .frame(maxWidth: .infinity)
            } else if let error = details.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else if details.files.isEmpty {
                Text("No changed files")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(details.files) { file in
                        HistoricalFileRow(
                            file: file,
                            showsCopied: copiedKey == fileCopiedKey(for: file.path)
                        )
                            .contextMenu {
                                Button("Copy Full Path") {
                                    onCopyPath(file.path, repository)
                                }
                                Button("Open Current Version") {
                                    EditorLauncher.openCurrentVersion(path: file.path, in: repository)
                                }
                                .disabled(!EditorLauncher.currentVersionExists(path: file.path, in: repository))
                            }
                    }
                }
            }
        }
    }
}

private struct CommitRow: View {
    let commit: RecentCommitSummary
    let isExpanded: Bool
    let showsCopied: Bool
    let onToggle: () -> Void
    let onCopySHA: () -> Void
    let onCopySubject: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 8)
                Text(commit.shortSHA)
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(commit.subject.isEmpty ? "(no message)" : commit.subject)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if showsCopied {
                    Label("Copied", systemImage: "checkmark")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                } else {
                    Text(commit.committedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                publicationLabel(commit.publicationStatus)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(isHovering ? Color.primary.opacity(0.04) : Color.clear)
        )
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .contextMenu {
            Button("Copy SHA", action: onCopySHA)
            Button("Copy Subject", action: onCopySubject)
        }
    }

    private func publicationLabel(_ status: CommitPublicationStatus) -> some View {
        let title: String
        let color: Color
        let background: Color
        let help: String
        switch status {
        case .onUpstream(let upstream):
            title = "On upstream"
            color = .green
            background = Color.green.opacity(0.15)
            help = "Reachable from \(upstream) according to local remote-tracking refs. Diffy does not fetch."
        case .localOnly(let upstream):
            title = "Local only"
            color = .orange
            background = Color.orange.opacity(0.15)
            help = "Not reachable from \(upstream) according to local remote-tracking refs. Diffy does not fetch."
        case .noUpstream:
            title = "No upstream"
            color = .secondary
            background = Color.primary.opacity(0.06)
            help = "This branch has no configured upstream."
        }
        return Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(background))
            .help(help)
    }
}

private struct HistoricalFileRow: View {
    let file: HistoricalChangedFile
    let showsCopied: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(file.displayStatus)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .leading)

            Text(file.previousPath.map { "\($0) → \(file.path)" } ?? file.path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 6)

            if showsCopied {
                Label("Copied", systemImage: "checkmark")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            } else if file.isBinary {
                Text("binary")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("+\(file.addedLines) -\(file.removedLines)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(isHovering ? Color.primary.opacity(0.04) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }
}

private struct CompactFileRow: View {
    let file: ChangedFileSummary
    let diffColors: DiffColors
    let showsCopied: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(file.displayStatus)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .leading)

            Text(file.path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 6)

            if showsCopied {
                Label("Copied", systemImage: "checkmark")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            } else if file.isBinary {
                Text("binary")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if file.isTooLarge {
                Text("large")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 3) {
                    Text("+\(file.addedLines)")
                        .foregroundStyle(AppColor.swiftUIColor(hex: diffColors.additionHex))
                    Text("-\(file.removedLines)")
                        .foregroundStyle(AppColor.swiftUIColor(hex: diffColors.removalHex))
                }
                .font(.system(.caption2, design: .monospaced))
            }
        }
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(isHovering ? Color.primary.opacity(0.04) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }
}
