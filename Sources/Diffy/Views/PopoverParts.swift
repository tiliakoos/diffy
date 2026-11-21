import DiffyCore
import SwiftUI

/// Small section title inside the popover: "Conflicts", "Staged", "Not pushed".
struct SectionTitle: View {
    let title: String
    var count: String? = nil
    var isWarning = false

    var body: some View {
        HStack {
            Text(title).foregroundStyle(isWarning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            Spacer()
            if let count {
                Text(count).fontWeight(.regular).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.top, 7)
        .padding(.bottom, 2)
    }
}

/// A file's status as a word. Modified files carry none; that is the common case.
struct StatusWord: View {
    let status: String

    var body: some View {
        if let word = Self.word(for: status) {
            Text(word)
                .font(.caption2.weight(status == "!" ? .semibold : .regular))
                .foregroundStyle(status == "!" ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                .fixedSize()
        }
    }

    static func word(for status: String) -> String? {
        switch status {
        case "A", "U": "new"
        case "D": "deleted"
        case "R": "renamed"
        case "C": "copied"
        case "!": "conflict"
        default: nil
        }
    }
}

/// `+a −b` for one file or repository, or "binary" / "large" when there are no line counts.
/// With `hidesZero`, a zero side is left out ("+45", not "+45 −0").
struct FileCounts: View {
    let added: Int
    let removed: Int
    let isBinary: Bool
    var isTooLarge = false
    var hidesZero = false
    let colors: DiffColors

    var body: some View {
        Group {
            if isBinary {
                Text(hidesZero ? "binary" : "Binary").font(.caption).foregroundStyle(.secondary)
            } else if isTooLarge {
                Text(hidesZero ? "large" : "Large").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 5) {
                    if !hidesZero || added > 0 {
                        Text("+\(added.formatted(.number))").foregroundStyle(colors.additionColor)
                    }
                    if !hidesZero || removed > 0 {
                        Text("\u{2212}\(removed.formatted(.number))").foregroundStyle(colors.removalColor)
                    }
                }
                .font(.caption)
                .monospacedDigit()
            }
        }
        // Counts never wrap or truncate; the text beside them gives way instead.
        .fixedSize()
    }
}

/// Actions that appear on hover over the end of a row's dim text, so the numbers never move.
/// The fade lets them sit on top of a long folder or branch name.
struct HoverActions<Content: View>: View {
    /// The row under it has the hover fill, so the fade matches it.
    var isOnFill = false
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 1) { content }
            .padding(.leading, 14)
            .background {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    if isOnFill { Color.primary.opacity(0.06) }
                }
                .mask(
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.45)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            }
    }
}

/// A changed file's name and folder, its status word and its counts. Used by working-tree rows
/// and by a commit's file list.
struct ChangeRowLabel<Actions: View>: View {
    let path: String
    let status: String
    let added: Int
    let removed: Int
    let isBinary: Bool
    var isTooLarge = false
    let colors: DiffColors
    var showsCopied = false
    var showsActions = false
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text((path as NSString).lastPathComponent)
                    .strikethrough(status == "D")
                    .foregroundStyle(status == "D" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .layoutPriority(1) // name first: the folder truncates before the file name does
                let folder = (path as NSString).deletingLastPathComponent
                if !folder.isEmpty {
                    Text(folder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                if showsActions {
                    HoverActions(isOnFill: true) { actions }
                }
            }
            if showsCopied {
                CopiedLabel()
            } else {
                StatusWord(status: status)
                if added + removed > 0 || isBinary || isTooLarge {
                    FileCounts(added: added, removed: removed, isBinary: isBinary, isTooLarge: isTooLarge, hidesZero: true, colors: colors)
                }
            }
        }
    }
}

/// A working-tree file row: click opens the file, hover reveals Reveal in Finder and Copy Path.
struct FileRow: View {
    let file: ChangedFileSummary
    let colors: DiffColors
    let showsCopied: Bool
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onCopyPath: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            ChangeRowLabel(
                path: file.path,
                status: file.displayStatus,
                added: file.addedLines,
                removed: file.removedLines,
                isBinary: file.isBinary,
                isTooLarge: file.isTooLarge,
                colors: colors,
                showsCopied: showsCopied,
                showsActions: isHovering
            ) {
                RowActionButton(symbol: "magnifyingglass", title: "Reveal in Finder", action: onReveal)
                RowActionButton(symbol: "doc.on.doc", title: "Copy Path", action: onCopyPath)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!file.isOpenableFromWorkingTree)
        .help(file.isOpenableFromWorkingTree ? "Open file" : "Deleted files cannot be opened from the working tree.")
        .frame(height: 26)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Copy Full Path", action: onCopyPath)
            Button("Reveal in Finder", action: onReveal)
        }
    }
}

struct RowActionButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

struct CopiedLabel: View {
    var body: some View {
        Label("Copied", systemImage: "checkmark")
            .font(.caption)
            .foregroundStyle(.green)
            .transition(.opacity)
            .fixedSize()
    }
}

/// A thin rule with a label in the middle: where the upstream sits in a commit list.
struct UpstreamLine: View {
    let title: String
    let help: String

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.separator).frame(height: 1)
            Text(title).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
            Rectangle().fill(.separator).frame(height: 1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .help(help)
    }
}

/// The guide line that worktrees hang off, left of their rows.
struct WorktreeGuide: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(.separator)
                    .frame(width: 1)
                    .padding(.leading, 6)
                    .padding(.bottom, 6)
            }
            .padding(.leading, 8)
    }
}

/// "17 d", "6 min", "now": one unit, never "17 days, 1 hr ago".
func compactAge(since date: Date, now: Date = Date()) -> String {
    let seconds = max(now.timeIntervalSince(date), 0)
    let minutes = seconds / 60, hours = minutes / 60, days = hours / 24
    if seconds < 60 { return "now" }
    if minutes < 60 { return "\(Int(minutes)) min" }
    if hours < 24 { return "\(Int(hours)) hr" }
    if days < 14 { return "\(Int(days)) d" }
    if days < 60 { return "\(Int(days / 7)) wk" }
    if days < 365 { return "\(Int(days / 30)) mo" }
    return "\(Int(days / 365)) yr"
}

/// Key under which a file row shows "Copied"; the popover sets it and the history section reads it.
func fileCopiedKey(_ relativePath: String, in repository: RepositoryConfig) -> String {
    "file:\(repository.id.uuidString):\(relativePath)"
}

/// The branch worth showing under a repository's name: nil when it's unknown, or when the row is
/// already named after it, as every auto-discovered worktree on a branch is.
func distinctBranch(_ branch: BranchInfo?, for repository: RepositoryConfig) -> BranchInfo? {
    switch branch {
    case .branch(let name)? where name == repository.displayName:
        nil
    case .unknown?:
        nil
    default:
        branch
    }
}

/// The branch as one line of text: its name, "detached at 1447b6e", or "bare".
func branchLabel(_ branch: BranchInfo?) -> String? {
    switch branch {
    case .branch(let name)?: name
    case .detached(let sha)?: "detached at \(sha)"
    case .bare?: "bare"
    default: nil
    }
}

/// Footer row styled like the bottom rows of Apple's menu extras ("Wi‑Fi Settings…").
struct MenuRow: View {
    let title: String
    var shortcut: String? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.caption)
                        .foregroundStyle(isHovering ? Color.white.opacity(0.75) : Color(nsColor: .tertiaryLabelColor))
                }
            }
            .frame(height: 26)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovering ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering ? Color.accentColor : Color.clear)
        )
        .padding(.horizontal, 6)
        .onHover { isHovering = $0 }
    }
}

/// Small disclosure row: "› 7 more files", "› 4 clean worktrees", "⌄ Show fewer".
struct DisclosureRow: View {
    let title: String
    let isExpanded: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                // Snaps, never animates: the popover resizes to its content (see PopoverView).
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text(title)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(height: 22)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { isHovering = $0 }
    }
}
