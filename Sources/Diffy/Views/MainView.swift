import AppKit
import DiffyCore
import SwiftUI

struct MainView: View {
    @ObservedObject var store: DiffyStore

    @Environment(\.openSettings) private var openSettings

    @State private var selectedGroupID: UUID?
    @State private var pendingGroupRemoval: UUID?
    @State private var pendingRepositoryPath: String?
    @State private var selectedRepositoryID: UUID?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            selectFirstGroupIfNeeded()
        }
        .onChange(of: store.groups) { _, _ in
            selectFirstGroupIfNeeded()
        }
        .sheet(isPresented: repositorySettingsPresented) {
            if let id = selectedRepositoryID {
                RepositorySettingsView(
                    store: store,
                    repositoryID: id,
                    onClose: { selectedRepositoryID = nil }
                )
            }
        }
        .sheet(isPresented: repositoryDestinationPresented) {
            if let path = pendingRepositoryPath {
                RepositoryDestinationSheet(path: path, groups: store.groups) { destination in
                    store.addRepository(path: path, destination: destination)
                    pendingRepositoryPath = nil
                } onCancel: {
                    pendingRepositoryPath = nil
                }
            }
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: groupRemovalDialogPresented,
            titleVisibility: .visible
        ) {
            Button("Dissolve into standalone groups") {
                if let id = pendingGroupRemoval {
                    store.removeGroup(id, mode: .dissolveIntoStandalone)
                }
                pendingGroupRemoval = nil
            }
            Button("Delete group and its repositories", role: .destructive) {
                if let id = pendingGroupRemoval {
                    store.removeGroup(id, mode: .deleteRepos)
                }
                pendingGroupRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                pendingGroupRemoval = nil
            }
        } message: {
            Text("Choose whether to keep this group's repositories as standalone groups or remove them from Diffy.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedGroupID) {
                Section("Groups") {
                    ForEach(store.groups) { group in
                        GroupNavigationRow(
                            store: store,
                            group: group,
                            repositoryCount: store.repositories.filter {
                                $0.groupID == group.id && $0.parentRepositoryID == nil
                            }.count
                        )
                        .tag(group.id)
                    }
                    .onMove { offsets, destination in
                        var ids = store.groups.map(\.id)
                        ids.move(fromOffsets: offsets, toOffset: destination)
                        store.reorderGroups(ids)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Button(action: chooseRepository) {
                    Label("Add Repository", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("o", modifiers: .command)

                Button {
                    let group = store.addGroup()
                    selectedGroupID = group.id
                } label: {
                    Label("New Group", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("n", modifiers: .command)

                Button {
                    openSettings()
                } label: {
                    Label("Settings…", systemImage: "gear")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)

                if let addError = store.lastAddError {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(addError)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .font(.caption)
                }

                if let loadError = store.lastLoadError {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(loadError)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .font(.caption)
                }
            }
            .padding(12)
        }
        .background(.regularMaterial)
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedGroupID,
           store.groups.contains(where: { $0.id == id }) {
            GroupInspectorView(
                store: store,
                groupID: id,
                onAddRepository: chooseRepository,
                onRemoveRequested: { pendingGroupRemoval = id },
                onRepositorySettings: { selectedRepositoryID = $0 }
            )
            .id(id)
        } else {
            ContentUnavailableView {
                Label("No Groups", systemImage: "folder.badge.plus")
            } description: {
                Text("Add a repository or create a group to start managing Diffy.")
            } actions: {
                Button("Add Repository", action: chooseRepository)
                Button("New Group") {
                    let group = store.addGroup()
                    selectedGroupID = group.id
                }
            }
        }
    }

    private var confirmationTitle: String {
        guard let id = pendingGroupRemoval,
              let group = store.groups.first(where: { $0.id == id })
        else { return "Remove group" }
        let name = group.name.isEmpty ? "this group" : "\"\(group.name)\""
        return "Remove \(name)?"
    }

    private var groupRemovalDialogPresented: Binding<Bool> {
        Binding {
            pendingGroupRemoval != nil
        } set: { newValue in
            if !newValue { pendingGroupRemoval = nil }
        }
    }

    private var repositoryDestinationPresented: Binding<Bool> {
        Binding {
            pendingRepositoryPath != nil
        } set: { newValue in
            if !newValue { pendingRepositoryPath = nil }
        }
    }

    private var repositorySettingsPresented: Binding<Bool> {
        Binding {
            selectedRepositoryID != nil
        } set: { newValue in
            if !newValue { selectedRepositoryID = nil }
        }
    }

    private func chooseRepository() {
        store.clearAddError()
        RepositoryPicker.chooseRepository { url in
            pendingRepositoryPath = url.path
        }
    }

    private func selectFirstGroupIfNeeded() {
        if !store.groups.contains(where: { $0.id == selectedGroupID }) {
            selectedGroupID = store.groups.first?.id
        }
    }
}

private struct GroupNavigationRow: View {
    @ObservedObject var store: DiffyStore
    let group: RepositoryGroup
    let repositoryCount: Int

    var body: some View {
        let totals = store.aggregateVisibleTotals(groupID: group.id)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name.isEmpty ? "Unnamed group" : group.name)
                Text("\(repositoryCount) \(repositoryCount == 1 ? "repository" : "repositories")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 3) {
                Text("+\(totals.added)")
                    .foregroundStyle(AppColor.swiftUIColor(hex: group.diffColors.additionHex))
                Text("-\(totals.removed)")
                    .foregroundStyle(AppColor.swiftUIColor(hex: group.diffColors.removalHex))
            }
            .font(.system(.caption, design: .monospaced))

            Button {
                store.setGroupHidden(group.id, isHidden: !group.isHidden)
            } label: {
                Image(systemName: group.isHidden ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(group.isHidden ? "Show in menu bar" : "Hide from menu bar")
            .accessibilityLabel(group.isHidden ? "Show in menu bar" : "Hide from menu bar")
        }
        .opacity(group.isHidden ? 0.6 : 1)
    }
}

private struct GroupInspectorView: View {
    @ObservedObject var store: DiffyStore
    let groupID: UUID
    let onAddRepository: () -> Void
    let onRemoveRequested: () -> Void
    let onRepositorySettings: (UUID) -> Void

    @State private var nameDraft = ""
    @State private var showingColorEditor = false
    @State private var showingBadgeEditor = false
    @FocusState private var isNameFocused: Bool

    private var group: RepositoryGroup? {
        store.groups.first { $0.id == groupID }
    }

    private var repositories: [RepositoryConfig] {
        store.orderedRepositories(in: groupID, includeHidden: true)
    }

    var body: some View {
        if let group {
            Form {
                Section("Group") {
                    TextField("Name", text: $nameDraft)
                        .focused($isNameFocused)
                        .onSubmit(commitName)

                    Toggle("Show in menu bar", isOn: visibilityBinding(for: group))
                        .toggleStyle(.switch)

                    LabeledContent("Appearance") {
                        HStack(spacing: 10) {
                            Button("Colors…") {
                                showingColorEditor.toggle()
                            }
                            .popover(isPresented: $showingColorEditor) {
                                GroupColorEditor(store: store, groupID: groupID)
                                    .padding(12)
                            }

                            Button("Menu Bar Label…") {
                                showingBadgeEditor.toggle()
                            }
                            .popover(isPresented: $showingBadgeEditor) {
                                GroupBadgeLabelEditor(store: store, groupID: groupID)
                                    .padding(12)
                                    .frame(width: 320)
                            }
                        }
                    }
                }

                Section {
                    if repositories.isEmpty {
                        Text("This group has no repositories yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(repositories) { repository in
                            RepositoryManagerRow(
                                repository: repository,
                                branch: store.summaries[repository.id]?.branch,
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

                Section {
                    Button("Remove Group…", role: .destructive) {
                        if repositories.isEmpty {
                            store.removeGroup(groupID, mode: .dissolveIntoStandalone)
                        } else {
                            onRemoveRequested()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(group.name.isEmpty ? "New Group" : group.name)
            .onAppear {
                nameDraft = group.name
            }
            .onChange(of: group.name) { _, newValue in
                if nameDraft != newValue {
                    nameDraft = newValue
                }
            }
            .onChange(of: isNameFocused) { _, focused in
                if !focused {
                    commitName()
                }
            }
        } else {
            ContentUnavailableView("Group unavailable", systemImage: "questionmark.folder")
        }
    }

    private func visibilityBinding(for group: RepositoryGroup) -> Binding<Bool> {
        Binding {
            !group.isHidden
        } set: { isVisible in
            store.setGroupHidden(groupID, isHidden: !isVisible)
        }
    }

    private func inclusionBinding(for repository: RepositoryConfig) -> Binding<Bool> {
        Binding {
            !(store.repositories.first { $0.id == repository.id }?.isHidden ?? false)
        } set: { isIncluded in
            store.setHidden(repository.id, isHidden: !isIncluded)
        }
    }

    private func commitName() {
        store.renameGroup(groupID, to: nameDraft)
    }
}

private struct RepositoryManagerRow: View {
    let repository: RepositoryConfig
    let branch: BranchInfo?
    @Binding var isIncluded: Bool
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(repository.displayName)
                    .lineLimit(1)
                BranchSubtitle(branch: branch)
                Text(repository.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.leading, repository.parentRepositoryID == nil ? 0 : 20)

            Spacer()

            Toggle("Count in totals", isOn: $isIncluded)
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Count in totals — include this repository in the group's menu-bar totals and popover")
                .accessibilityLabel("Count in totals")

            Button("Settings…", action: onSettings)
        }
        .opacity(repository.isHidden ? 0.6 : 1)
    }
}

private struct RepositoryDestinationSheet: View {
    private enum Choice: Hashable {
        case newGroup
        case existingGroup
    }

    let path: String
    let groups: [RepositoryGroup]
    let onAdd: (RepositoryDestination) -> Void
    let onCancel: () -> Void

    @State private var choice: Choice = .newGroup
    @State private var selectedGroupID: UUID?

    init(
        path: String,
        groups: [RepositoryGroup],
        onAdd: @escaping (RepositoryDestination) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.path = path
        self.groups = groups
        self.onAdd = onAdd
        self.onCancel = onCancel
        _selectedGroupID = State(initialValue: groups.first?.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Repository")
                .font(.headline)

            Text(URL(fileURLWithPath: path).lastPathComponent)
                .font(.body.weight(.medium))
            Text(path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Picker("Add to", selection: $choice) {
                Text("New Group").tag(Choice.newGroup)
                if !groups.isEmpty {
                    Text("Existing Group").tag(Choice.existingGroup)
                }
            }
            .pickerStyle(.segmented)

            if choice == .newGroup {
                Text("A new group named after this repository will be created after validation succeeds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Group", selection: $selectedGroupID) {
                    ForEach(groups) { group in
                        Text(group.name.isEmpty ? "Unnamed group" : group.name)
                            .tag(group.id as UUID?)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Add Repository") {
                    switch choice {
                    case .newGroup:
                        onAdd(.newGroup)
                    case .existingGroup:
                        if let selectedGroupID {
                            onAdd(.existingGroup(selectedGroupID))
                        }
                    }
                }
                .disabled(choice == .existingGroup && selectedGroupID == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
