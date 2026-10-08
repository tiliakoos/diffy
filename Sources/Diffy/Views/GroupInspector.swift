import AppKit
import DiffyCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings for one group in the manager window: a live menu-bar preview with the label,
/// colors and visibility edited inline, then the group's repositories.
struct GroupInspector: View {
    @ObservedObject var store: DiffyStore
    let groupID: UUID
    let onAddRepository: () -> Void
    let onRemoveRequested: () -> Void
    let onRepositorySettings: (UUID) -> Void

    private enum Field: Hashable {
        case name
        case label
    }

    @State private var nameDraft = ""
    @State private var labelDraft = ""
    @FocusState private var focusedField: Field?

    private var group: RepositoryGroup? {
        store.groups.first { $0.id == groupID }
    }

    private var groupIndex: Int {
        store.groups.firstIndex { $0.id == groupID } ?? 0
    }

    private var repositories: [RepositoryConfig] {
        store.orderedRepositories(in: groupID, includeHidden: true)
    }

    var body: some View {
        if let group {
            Form {
                Section {
                    menuBarPreview(for: group)
                    Toggle("Show in menu bar", isOn: visibilityBinding(for: group))
                        .toggleStyle(.switch)
                    LabeledContent("Label") {
                        HStack(spacing: 8) {
                            TextField("", text: $labelDraft, prompt: Text("S"))
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.center)
                                .frame(width: 56)
                                .focused($focusedField, equals: .label)
                                .onSubmit(commitLabel)
                                .onChange(of: labelDraft) { _, newValue in
                                    if newValue.count > 2 {
                                        labelDraft = String(newValue.prefix(2))
                                    }
                                }
                            Picker("", selection: labelPositionBinding(for: group)) {
                                Text("Before counts").tag(BadgeLabelPosition.leading)
                                Text("After counts").tag(BadgeLabelPosition.trailing)
                            }
                            .labelsHidden()
                            .fixedSize()
                            .disabled(group.badgeLabel == nil)
                        }
                    }
                    LabeledContent("Color") {
                        HStack(spacing: 8) {
                            GroupTile(group: group, index: groupIndex)
                            ColorPicker("Group color", selection: tileColorBinding(for: group))
                                .labelsHidden()
                            Button("Automatic") {
                                store.updateGroupColor(groupID, colorHex: nil)
                            }
                            .disabled(group.colorHex == nil)
                        }
                    }
                    LabeledContent("Diff colors") {
                        HStack(spacing: 8) {
                            ColorPicker("Additions", selection: diffColorBinding(for: group, keyPath: \.additionHex))
                                .labelsHidden()
                                .help("Addition color")
                            ColorPicker("Removals", selection: diffColorBinding(for: group, keyPath: \.removalHex))
                                .labelsHidden()
                                .help("Removal color")
                            Button("System") {
                                store.updateGroupColors(groupID, diffColors: .default)
                            }
                            .disabled(group.diffColors == .default)
                        }
                    }
                } header: {
                    Text("Menu Bar")
                } footer: {
                    Text("Up to two characters or one emoji for the label. System diff colors adapt to dark mode; custom ones don't.")
                }

                Section {
                    if repositories.isEmpty {
                        Text("This group has no repositories yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(repositories) { repository in
                            RepositoryRow(
                                repository: repository,
                                summary: store.summaries[repository.id],
                                colors: group.diffColors,
                                isIncluded: inclusionBinding(for: repository),
                                onSettings: { onRepositorySettings(repository.id) }
                            )
                        }
                    }
                } header: {
                    HStack {
                        Text("Repositories")
                        Spacer()
                        Button("Add Repository", action: onAddRepository)
                    }
                }

                Section("Group") {
                    TextField("Name", text: $nameDraft)
                        .focused($focusedField, equals: .name)
                        .onSubmit(commitName)
                    Button("Remove Group…", role: .destructive, action: onRemoveRequested)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(group.name.isEmpty ? "New Group" : group.name)
            .onAppear {
                nameDraft = group.name
                labelDraft = group.badgeLabel?.text ?? ""
            }
            .onChange(of: group.name) { _, newValue in
                if nameDraft != newValue { nameDraft = newValue }
            }
            .onChange(of: group.badgeLabel?.text ?? "") { _, newValue in
                if labelDraft != newValue { labelDraft = newValue }
            }
            .onChange(of: focusedField) { previous, _ in
                switch previous {
                case .name: commitName()
                case .label: commitLabel()
                case nil: break
                }
            }
        } else {
            ContentUnavailableView("Group unavailable", systemImage: "questionmark.folder")
        }
    }

    private func menuBarPreview(for group: RepositoryGroup) -> some View {
        let totals = store.aggregateVisibleTotals(groupID: groupID)
        let image = BadgeRenderer.image(
            added: totals.added,
            removed: totals.removed,
            colors: group.diffColors,
            badgeLabel: group.badgeLabel,
            interface: .modern
        )
        return Image(nsImage: image)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .accessibilityLabel("Menu bar preview")
    }

    // MARK: - Commits

    private func commitName() {
        store.renameGroup(groupID, to: nameDraft)
    }

    private func commitLabel() {
        guard let group else { return }
        let trimmed = labelDraft.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            store.updateGroupBadgeLabel(groupID, badgeLabel: nil)
        } else {
            let position = Self.modernPosition(group.badgeLabel?.position ?? .leading)
            store.updateGroupBadgeLabel(groupID, badgeLabel: BadgeLabel(text: String(trimmed.prefix(2)), position: position))
        }
    }

    /// The modern badge draws the label before or after the counts only; the classic
    /// above/below positions read as "before".
    private static func modernPosition(_ position: BadgeLabelPosition) -> BadgeLabelPosition {
        position == .trailing ? .trailing : .leading
    }

    // MARK: - Bindings

    private func visibilityBinding(for group: RepositoryGroup) -> Binding<Bool> {
        Binding {
            !group.isHidden
        } set: { isVisible in
            store.setGroupHidden(groupID, isHidden: !isVisible)
        }
    }

    private func labelPositionBinding(for group: RepositoryGroup) -> Binding<BadgeLabelPosition> {
        Binding {
            Self.modernPosition(group.badgeLabel?.position ?? .leading)
        } set: { position in
            guard let label = group.badgeLabel else { return }
            store.updateGroupBadgeLabel(groupID, badgeLabel: BadgeLabel(text: label.text, position: position))
        }
    }

    private func tileColorBinding(for group: RepositoryGroup) -> Binding<Color> {
        Binding {
            AppColor.swiftUIColor(hex: group.colorHex ?? GroupTile.defaultColorHex(index: groupIndex))
        } set: { color in
            store.updateGroupColor(groupID, colorHex: AppColor.hex(color))
        }
    }

    private func diffColorBinding(for group: RepositoryGroup, keyPath: WritableKeyPath<DiffColors, String>) -> Binding<Color> {
        Binding {
            AppColor.swiftUIColor(hex: group.diffColors[keyPath: keyPath])
        } set: { color in
            var colors = group.diffColors
            colors[keyPath: keyPath] = AppColor.hex(color)
            store.updateGroupColors(groupID, diffColors: colors)
        }
    }

    private func inclusionBinding(for repository: RepositoryConfig) -> Binding<Bool> {
        Binding {
            !(store.repositories.first { $0.id == repository.id }?.isHidden ?? false)
        } set: { isIncluded in
            store.setHidden(repository.id, isHidden: !isIncluded)
        }
    }
}

private struct RepositoryRow: View {
    let repository: RepositoryConfig
    let summary: RepoDiffSummary?
    let colors: DiffColors
    @Binding var isIncluded: Bool
    let onSettings: () -> Void

    private static let folderIcon: NSImage = {
        let icon = NSWorkspace.shared.icon(for: .folder)
        icon.size = NSSize(width: 22, height: 22)
        return icon
    }()

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: Self.folderIcon)
            VStack(alignment: .leading, spacing: 1) {
                Text(repository.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    BranchSubtitle(branch: summary?.branch)
                    Text((repository.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.leading, repository.parentRepositoryID == nil ? 0 : 20)

            Spacer()

            status

            Button(action: onSettings) {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("Repository settings")
            .accessibilityLabel("Settings for \(repository.displayName)")
        }
        .opacity(repository.isHidden ? 0.6 : 1)
        .contextMenu {
            Button("Settings…", action: onSettings)
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(repository.path, forType: .string)
            }
            Toggle("Count in totals", isOn: $isIncluded)
        }
    }

    @ViewBuilder
    private var status: some View {
        if repository.isHidden {
            Text("Not counted").font(.caption).foregroundStyle(.tertiary)
        } else if let summary {
            if summary.errorMessage != nil {
                Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if summary.addedLines == 0, summary.removedLines == 0 {
                Text("No changes").font(.caption).foregroundStyle(.tertiary)
            } else {
                FileCounts(added: summary.addedLines, removed: summary.removedLines, isBinary: false, colors: colors)
            }
        }
    }
}
