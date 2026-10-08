import DiffyCore
import SwiftUI

/// Rounded platter behind one repository when a popover shows several.
struct Platter<Content: View>: View {
    var indented = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .padding(.leading, indented ? 24 : 8)
            .padding(.trailing, 8)
    }
}

/// Section header inside the popover: title at the left, a count at the right.
struct SectionHeader: View {
    let title: String
    let fileCount: Int

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text("^[\(fileCount) file](inflect: true)").fontWeight(.regular).foregroundStyle(.tertiary).monospacedDigit()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

/// Thin green/red split of a repository's or group's line counts.
struct RatioBar: View {
    let added: Int
    let removed: Int
    let colors: DiffColors

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                colors.additionColor.frame(width: geometry.size.width * fraction)
                colors.removalColor
            }
        }
        .frame(height: 4)
        .clipShape(Capsule())
    }

    private var fraction: CGFloat {
        let total = added + removed
        return total == 0 ? 1 : CGFloat(added) / CGFloat(total)
    }
}

/// Status letter in a small tile. The letter carries the meaning; color is a second channel.
struct StatusTile: View {
    let status: String

    var body: some View {
        Text(status)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 16, height: 16)
            .background(
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
    }

    private var color: Color {
        switch status {
        case "A": .green
        case "D": .red
        case "!": .orange
        case "U": .blue
        default: .secondary
        }
    }
}

/// `+a −b` for one file, or "Binary" / "Large" when there are no line counts.
struct FileCounts: View {
    let added: Int
    let removed: Int
    let isBinary: Bool
    var isTooLarge = false
    let colors: DiffColors

    var body: some View {
        if isBinary {
            Text("Binary").font(.caption).foregroundStyle(.secondary)
        } else if isTooLarge {
            Text("Large").font(.caption).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 5) {
                Text("+\(added.formatted(.number))").foregroundStyle(colors.additionColor)
                Text("\u{2212}\(removed.formatted(.number))").foregroundStyle(colors.removalColor)
            }
            .font(.caption)
            .monospacedDigit()
        }
    }
}

/// The visual part of a changed-file row: file name first, folder dimmed, counts, status tile.
struct ChangeRowLabel<Trailing: View>: View {
    let path: String
    let status: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 7) {
            Text((path as NSString).lastPathComponent)
                .lineLimit(1)
            let folder = (path as NSString).deletingLastPathComponent
            if !folder.isEmpty {
                Text(folder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            trailing
            StatusTile(status: status)
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
            ChangeRowLabel(path: file.path, status: file.displayStatus) {
                if showsCopied {
                    CopiedLabel()
                } else {
                    FileCounts(
                        added: file.addedLines,
                        removed: file.removedLines,
                        isBinary: file.isBinary,
                        isTooLarge: file.isTooLarge,
                        colors: colors
                    )
                }
                if isHovering {
                    RowActionButton(symbol: "magnifyingglass", title: "Reveal in Finder", action: onReveal)
                    RowActionButton(symbol: "doc.on.doc", title: "Copy Path", action: onCopyPath)
                }
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
    }
}

/// Key under which a file row shows "Copied"; the popover sets it and the history section reads it.
func fileCopiedKey(_ relativePath: String, in repository: RepositoryConfig) -> String {
    "file:\(repository.id.uuidString):\(relativePath)"
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

/// Footer-sized "Show 10 more files" / "Show fewer" control.
struct DisclosureRow: View {
    let title: String
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text(title)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(height: 24)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
