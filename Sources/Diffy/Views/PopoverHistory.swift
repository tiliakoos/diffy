import DiffyCore
import SwiftUI

/// One repository's recent commits in the popover's History segment. Loads lazily on first
/// appearance; the store decides whether a reopen needs a refetch.
struct HistorySection: View {
    @ObservedObject var store: DiffyStore
    let repository: RepositoryConfig
    let useCardChrome: Bool
    let colors: DiffColors
    let copiedKey: String?
    let onCopy: (String, String) -> Void
    let onCopyPath: (String, RepositoryConfig) -> Void

    @State private var expandedSHA: String?

    private var history: CommitHistoryState? {
        store.commitHistories[repository.id]
    }

    var body: some View {
        Group {
            if useCardChrome {
                Platter(indented: repository.parentRepositoryID != nil) { content }
            } else {
                content
            }
        }
        .onAppear {
            store.loadRecentCommits(repositoryID: repository.id)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            if useCardChrome {
                header.padding(.horizontal, 10)
            }
            commits.padding(.horizontal, useCardChrome ? 2 : 6)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(repository.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                BranchSubtitle(branch: store.summaries[repository.id]?.branch)
            }
            Spacer(minLength: 8)
            publicationSummary
        }
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var publicationSummary: some View {
        if let commits = history?.commits, !commits.isEmpty {
            let notPushed = commits.filter { if case .localOnly = $0.publicationStatus { true } else { false } }.count
            if notPushed > 0 {
                Label("\(notPushed) not pushed", systemImage: "arrow.up.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            } else if commits.allSatisfy({ $0.publicationStatus == .noUpstream }) {
                Text("No upstream")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var commits: some View {
        if history?.isLoading == true, history?.commits.isEmpty == true {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        } else if let error = history?.errorMessage, history?.commits.isEmpty == true {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 8)
        } else if history?.commits.isEmpty == true {
            Text("No commits yet")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
        } else if let commits = history?.commits {
            ForEach(commits) { commit in
                commitRow(commit)
            }
            if let error = history?.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
            }
        }
    }

    private func commitRow(_ commit: RecentCommitSummary) -> some View {
        let key = "commit:\(repository.id.uuidString):\(commit.sha)"
        return VStack(alignment: .leading, spacing: 0) {
            CommitRow(
                commit: commit,
                isExpanded: expandedSHA == commit.sha,
                showsCopied: copiedKey == key,
                onToggle: {
                    withAnimation(.easeOut(duration: 0.18)) {
                        if expandedSHA == commit.sha {
                            expandedSHA = nil
                        } else {
                            expandedSHA = commit.sha
                            store.loadCommitDetails(repositoryID: repository.id, sha: commit.sha)
                        }
                    }
                },
                onCopySHA: { onCopy(commit.sha, key) },
                onCopySubject: { onCopy(commit.subject, key) }
            )
            if expandedSHA == commit.sha {
                details(for: commit.sha)
                    .padding(.leading, 18)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func details(for sha: String) -> some View {
        if let details = store.commitDetails[repository.id], details.sha == sha {
            if details.isLoading {
                ProgressView().controlSize(.mini).frame(maxWidth: .infinity)
            } else if let error = details.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 8)
            } else if details.files.isEmpty {
                Text("No changed files").font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 8)
            } else {
                ForEach(details.files) { file in
                    ChangeRowLabel(path: file.path, status: file.displayStatus) {
                        if copiedKey == fileCopiedKey(file.path, in: repository) {
                            CopiedLabel()
                        } else {
                            FileCounts(added: file.addedLines, removed: file.removedLines, isBinary: file.isBinary, colors: colors)
                        }
                    }
                    .font(.callout)
                    .frame(height: 24)
                    .padding(.horizontal, 8)
                    .contextMenu {
                        Button("Copy Full Path") { onCopyPath(file.path, repository) }
                        Button("Open Current Version") {
                            EditorLauncher.openCurrentVersion(path: file.path, in: repository, onError: store.reportEditorError)
                        }
                        .disabled(!EditorLauncher.currentVersionExists(path: file.path, in: repository))
                    }
                }
            }
        }
    }
}

/// One commit: a publication glyph, the subject, then SHA and age. Shapes differ per status so
/// color is never the only signal.
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
            HStack(alignment: .top, spacing: 8) {
                glyph
                    .font(.system(size: 14))
                    .frame(width: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(commit.subject.isEmpty ? "(no message)" : commit.subject)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 6) {
                        Text(commit.shortSHA)
                            .font(.system(.caption, design: .monospaced))
                        if showsCopied {
                            CopiedLabel()
                        } else {
                            Text("\(commit.committedAt, style: .relative) ago")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering || isExpanded ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Copy SHA", action: onCopySHA)
            Button("Copy Subject", action: onCopySubject)
        }
        .help(help)
    }

    @ViewBuilder
    private var glyph: some View {
        switch commit.publicationStatus {
        case .localOnly:
            Image(systemName: "arrow.up.circle").foregroundStyle(.orange)
        case .onUpstream:
            Image(systemName: "checkmark.circle").foregroundStyle(.green)
        case .noUpstream:
            Image(systemName: "minus.circle").foregroundStyle(.tertiary)
        }
    }

    private var help: String {
        switch commit.publicationStatus {
        case .onUpstream(let upstream):
            "On upstream: reachable from \(upstream) according to local remote-tracking refs. Diffy does not fetch."
        case .localOnly(let upstream):
            "Not pushed: not reachable from \(upstream) according to local remote-tracking refs. Diffy does not fetch."
        case .noUpstream:
            "This branch has no configured upstream."
        }
    }
}

struct HistoryLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            Label("Not pushed", systemImage: "arrow.up.circle").foregroundStyle(.orange)
            Label("On upstream", systemImage: "checkmark.circle").foregroundStyle(.green)
            Label("No upstream", systemImage: "minus.circle").foregroundStyle(.tertiary)
        }
        .font(.caption2)
        .labelStyle(.titleAndIcon)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}
