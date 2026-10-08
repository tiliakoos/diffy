import DiffyCore
import SwiftUI

/// The refreshed manager window: a sidebar of groups and an inspector for the selected one.
/// No custom backgrounds — NavigationSplitView draws its own sidebar material.
struct ManagerView: View {
    @ObservedObject var store: DiffyStore

    @State private var selectedGroupID: UUID?
    @State private var pendingGroupRemoval: UUID?
    @State private var selectedRepositoryID: UUID?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: addRepository) {
                    Label("Add Repository", systemImage: "plus")
                }
                .keyboardShortcut("o", modifiers: .command)
                .help("Add Repository (⌘O)")
            }
        }
        .onAppear(perform: selectFirstGroupIfNeeded)
        .onChange(of: store.groups) { _, _ in
            selectFirstGroupIfNeeded()
        }
        .onChange(of: store.repositories) { _, repositories in
            if let selectedRepositoryID,
               !repositories.contains(where: { $0.id == selectedRepositoryID }) {
                self.selectedRepositoryID = nil
            }
        }
        .sheet(isPresented: repositorySettingsPresented) {
            if let id = selectedRepositoryID {
                RepositorySettingsView(store: store, repositoryID: id, onClose: { selectedRepositoryID = nil })
            }
        }
        .alert(removalTitle, isPresented: groupRemovalPresented) {
            Button("Keep Repositories") { removeGroup(.dissolveIntoStandalone) }
            Button("Remove All", role: .destructive) { removeGroup(.deleteRepos) }
            Button("Cancel", role: .cancel) { pendingGroupRemoval = nil }
        } message: {
            Text(removalMessage)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedGroupID) {
            Section("Groups") {
                ForEach(Array(store.groups.enumerated()), id: \.element.id) { index, group in
                    GroupRow(
                        group: group,
                        index: index,
                        repositoryCount: repositoryCount(in: group.id),
                        totals: store.aggregateVisibleTotals(groupID: group.id)
                    )
                    .tag(group.id)
                    .contextMenu {
                        Button(group.isHidden ? "Show in Menu Bar" : "Hide from Menu Bar") {
                            store.setGroupHidden(group.id, isHidden: !group.isHidden)
                        }
                        Button("Remove Group…", role: .destructive) { requestRemoval(of: group.id) }
                    }
                }
                .onMove { offsets, destination in
                    var ids = store.groups.map(\.id)
                    ids.move(fromOffsets: offsets, toOffset: destination)
                    store.reorderGroups(ids)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                selectedGroupID = store.addGroup().id
            } label: {
                Label("New Group", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = selectedGroupID, store.groups.contains(where: { $0.id == id }) {
            GroupInspector(
                store: store,
                groupID: id,
                onAddRepository: addRepository,
                onRemoveRequested: { requestRemoval(of: id) },
                onRepositorySettings: { selectedRepositoryID = $0 }
            )
            .id(id)
        } else {
            ContentUnavailableView {
                Label("Welcome to Diffy", systemImage: "plusminus")
            } description: {
                Text("Add a repository and its working-tree changes appear in your menu bar. Diffy reads git locally and never writes to your repositories.")
            } actions: {
                Button("Add Repository…", action: addRepository)
                    .buttonStyle(.borderedProminent)
                Button("New Group") {
                    selectedGroupID = store.addGroup().id
                }
            }
        }
    }

    // MARK: - Actions

    private func addRepository() {
        store.clearAddError()
        RepositoryPicker.chooseRepository(groups: store.groups, preselectedGroupID: selectedGroupID) { url, destination in
            store.addRepository(path: url.path, destination: destination)
        }
    }

    private func requestRemoval(of groupID: UUID) {
        if store.repositories.contains(where: { $0.groupID == groupID }) {
            pendingGroupRemoval = groupID
        } else {
            store.removeGroup(groupID, mode: .dissolveIntoStandalone)
        }
    }

    private func removeGroup(_ mode: GroupRemovalMode) {
        if let id = pendingGroupRemoval {
            store.removeGroup(id, mode: mode)
        }
        pendingGroupRemoval = nil
    }

    private func selectFirstGroupIfNeeded() {
        if !store.groups.contains(where: { $0.id == selectedGroupID }) {
            selectedGroupID = store.groups.first?.id
        }
    }

    /// Repositories added to the group; worktrees found under them are not counted.
    private func repositoryCount(in groupID: UUID) -> Int {
        store.repositories.filter { $0.groupID == groupID && $0.parentRepositoryID == nil }.count
    }

    private var pendingGroup: RepositoryGroup? {
        store.groups.first { $0.id == pendingGroupRemoval }
    }

    private var removalTitle: String {
        guard let pendingGroup else { return "Remove group?" }
        let name = pendingGroup.name.isEmpty ? "this group" : "\u{201C}\(pendingGroup.name)\u{201D}"
        return "Remove \(name)?"
    }

    private var removalMessage: String {
        let count = pendingGroupRemoval.map(repositoryCount(in:)) ?? 0
        let repositories = count == 1 ? "Its repository" : "Its \(count) repositories"
        return "\(repositories) can stay in Diffy as separate groups, or be removed along with it. Files on disk aren't touched."
    }

    private var groupRemovalPresented: Binding<Bool> {
        Binding {
            pendingGroupRemoval != nil
        } set: { newValue in
            if !newValue { pendingGroupRemoval = nil }
        }
    }

    private var repositorySettingsPresented: Binding<Bool> {
        Binding {
            selectedRepositoryID != nil
        } set: { newValue in
            if !newValue { selectedRepositoryID = nil }
        }
    }
}

private struct GroupRow: View {
    let group: RepositoryGroup
    let index: Int
    let repositoryCount: Int
    let totals: (added: Int, removed: Int)

    var body: some View {
        HStack(spacing: 8) {
            GroupTile(group: group, index: index, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name.isEmpty ? "Unnamed group" : group.name)
                    .lineLimit(1)
                Text("^[\(repositoryCount) repository](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if group.isHidden {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.secondary)
                    .help("Hidden from the menu bar")
            } else if totals.added == 0, totals.removed == 0 {
                Image(systemName: "plusminus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("+\(totals.added.formatted(.number)) \u{2212}\(totals.removed.formatted(.number))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .opacity(group.isHidden ? 0.55 : 1)
    }
}
