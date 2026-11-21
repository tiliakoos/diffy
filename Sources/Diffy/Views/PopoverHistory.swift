import DiffyCore
import SwiftUI

private func isLocalOnly(_ commit: RecentCommitSummary) -> Bool {
    if case .localOnly = commit.publicationStatus { true } else { false }
}

private func upstreamName(_ commits: [RecentCommitSummary]) -> String? {
    commits.lazy.compactMap { commit -> String? in
        switch commit.publicationStatus {
        case .onUpstream(let upstream), .localOnly(let upstream): upstream
        case .noUpstream: nil
        }
    }.first
}

/// Unpushed commits among those loaded, "5+" when every loaded commit is unpushed (the
/// upstream is further back than Diffy looked).
private func unpushedLabel(_ commits: [RecentCommitSummary]) -> String? {
    let count = commits.filter(isLocalOnly).count
    guard count > 0 else { return nil }
    return count == commits.count ? "\(count)+" : "\(count)"
}

/// One repository in a group's History: its last commit and age, a chip only when something
/// needs attention. Click to open its commits.
struct HistoryRow: View {
    let repository: RepositoryConfig
    let history: CommitHistoryState?
    let errorTitle: String?
    let isOpen: Bool
    let onToggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        let commits = history?.commits ?? []
        let last = commits.first
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 10)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(repository.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(errorTitle == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if errorTitle == nil {
                        Text(last?.subject ?? (history?.isLoading == false ? "No commits yet" : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let errorTitle {
                    Label(errorTitle, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize()
                } else {
                    if let unpushed = unpushedLabel(commits) {
                        Text("\u{2191} \(unpushed)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.16)))
                            .fixedSize()
                            .help("Commits not on \(upstreamName(commits) ?? "the upstream"), according to your local copy. Diffy never fetches.")
                    } else if commits.contains(where: { $0.publicationStatus == .noUpstream }) {
                        Text("no upstream")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                            .fixedSize()
                    }
                    if let last {
                        Text(compactAge(since: last.committedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize()
                    }
                }
            }
            .frame(height: 26)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering || isOpen ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { isHovering = $0 }
    }
}

/// One repository's recent commits. Each unpushed commit has an orange dot; when they're all
/// at the top, one line marks where the upstream starts. Loads lazily; the store decides whether
/// a reopen needs a refetch.
struct CommitList: View {
    @ObservedObject var store: DiffyStore
    let repository: RepositoryConfig
    let colors: DiffColors
    let copiedKey: String?
    let onCopy: (String, String) -> Void
    let onCopyPath: (String, RepositoryConfig) -> Void

    @State private var expandedSHA: String?

    /// A commit's file list is capped like the working tree's, so one huge merge can't freeze
    /// the popover.
    private static let detailLimit = 50
    private static let fetchHelp = "Compared with your local copy of the upstream branch. Diffy never fetches."

    private var history: CommitHistoryState? {
        store.commitHistories[repository.id]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .onAppear {
            store.loadRecentCommits(repositoryID: repository.id)
        }
    }

    @ViewBuilder
    private var content: some View {
        let commits = history?.commits ?? []
        if history?.isLoading != false, commits.isEmpty {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        } else if let error = history?.errorMessage, commits.isEmpty {
            note(error)
        } else if commits.isEmpty {
            note("No commits yet")
        } else {
            let upstream = upstreamName(commits)
            let noUpstream = commits.contains { $0.publicationStatus == .noUpstream }
            let local = commits.filter(isLocalOnly)
            // After a merge, `git log`'s date order can put a pushed commit between unpushed
            // ones. The divider is only drawn when the unpushed commits are all at the top.
            let firstPushed = commits.firstIndex { !isLocalOnly($0) } ?? commits.count
            let isPrefix = !noUpstream && !local.isEmpty && !commits[firstPushed...].contains(where: isLocalOnly)

            if noUpstream {
                UpstreamLine(title: "no upstream branch", help: "This branch has no upstream, so there is nothing to compare with.")
            } else if isPrefix {
                SectionTitle(title: "Not pushed", count: unpushedLabel(commits), isWarning: true)
            } else if !local.isEmpty {
                SectionTitle(title: "\(local.count) not pushed", isWarning: true)
            } else {
                UpstreamLine(title: upstream ?? "upstream", help: Self.fetchHelp)
            }
            ForEach(Array(commits.enumerated()), id: \.element.sha) { index, commit in
                if isPrefix, index == firstPushed {
                    UpstreamLine(title: upstream ?? "upstream", help: Self.fetchHelp)
                }
                commitRow(commit)
                if expandedSHA == commit.sha {
                    details(for: commit.sha)
                        .padding(.leading, 14)
                }
            }
            if isPrefix, firstPushed == commits.count {
                UpstreamLine(title: "\(upstream ?? "upstream") is further back", help: Self.fetchHelp)
            }
            if let error = history?.errorMessage {
                note(error)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }

    private func commitRow(_ commit: RecentCommitSummary) -> some View {
        let key = "commit:\(repository.id.uuidString):\(commit.sha)"
        return CommitRow(
            commit: commit,
            isExpanded: expandedSHA == commit.sha,
            showsCopied: copiedKey == key,
            onToggle: {
                if expandedSHA == commit.sha {
                    expandedSHA = nil
                } else {
                    expandedSHA = commit.sha
                    store.loadCommitDetails(repositoryID: repository.id, sha: commit.sha)
                }
            },
            onCopySHA: { onCopy(commit.sha, key) },
            onCopySubject: { onCopy(commit.subject, key) }
        )
    }

    @ViewBuilder
    private func details(for sha: String) -> some View {
        if let details = store.commitDetails[repository.id], details.sha == sha {
            if details.isLoading {
                ProgressView().controlSize(.mini).frame(maxWidth: .infinity).padding(.vertical, 4)
            } else if let error = details.errorMessage {
                note(error)
            } else if details.files.isEmpty {
                note("No changed files")
            } else {
                ForEach(details.files.prefix(Self.detailLimit)) { file in
                    ChangeRowLabel(
                        path: file.path,
                        status: file.displayStatus,
                        added: file.addedLines,
                        removed: file.removedLines,
                        isBinary: file.isBinary,
                        colors: colors,
                        showsCopied: copiedKey == fileCopiedKey(file.path, in: repository)
                    ) {
                        EmptyView()
                    }
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
                if details.files.count > Self.detailLimit {
                    let more = details.files.count - Self.detailLimit
                    note("and \(more.formatted(.number)) more \(more == 1 ? "file" : "files")")
                }
            }
        }
    }
}

/// One commit on one line: an orange dot when it isn't pushed, the subject, and its age. The
/// SHA and a copy button appear on hover over the end of the subject.
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
                if isLocalOnly(commit) {
                    Circle().fill(Color.orange).frame(width: 6, height: 6).padding(.trailing, 2)
                        .accessibilityLabel("Not pushed")
                } else {
                    Color.clear.frame(width: 8, height: 6)
                }
                Text(commit.subject.isEmpty ? "(no message)" : commit.subject)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        if isHovering {
                            HoverActions(isOnFill: true) {
                                Text(commit.shortSHA)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .padding(.trailing, 2)
                                RowActionButton(symbol: "doc.on.doc", title: "Copy SHA", action: onCopySHA)
                            }
                        }
                    }
                if showsCopied {
                    CopiedLabel()
                } else {
                    Text(compactAge(since: commit.committedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            .frame(height: 26)
            .padding(.horizontal, 8)
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

    private var help: String {
        switch commit.publicationStatus {
        case .onUpstream(let upstream):
            "On \(upstream), according to your local copy. Diffy does not fetch."
        case .localOnly(let upstream):
            "Not on \(upstream) yet, according to your local copy. Diffy does not fetch."
        case .noUpstream:
            "This branch has no configured upstream."
        }
    }
}
