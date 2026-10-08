import AppKit
import DiffyCore

@MainActor
enum RepositoryPicker {
    static func chooseRepository(_ completion: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose a Git Repository"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            completion(url)
        }
    }

    /// Open panel with an "Add to" menu, so the destination group is chosen in the same step.
    static func chooseRepository(
        groups: [RepositoryGroup],
        preselectedGroupID: UUID?,
        _ completion: (URL, RepositoryDestination) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = "Add Repository"
        panel.prompt = "Add"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 25), pullsDown: false)
        popup.addItem(withTitle: "New Group")
        if !groups.isEmpty {
            popup.menu?.addItem(.separator())
        }
        for group in groups {
            let item = NSMenuItem(title: group.name.isEmpty ? "Unnamed group" : group.name, action: nil, keyEquivalent: "")
            item.representedObject = group.id
            popup.menu?.addItem(item)
        }
        if let preselectedGroupID,
           let index = popup.itemArray.firstIndex(where: { $0.representedObject as? UUID == preselectedGroupID }) {
            popup.selectItem(at: index)
        }

        let accessory = NSStackView(views: [NSTextField(labelWithString: "Add to:"), popup])
        accessory.orientation = .horizontal
        accessory.spacing = 8
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        accessory.frame = NSRect(x: 0, y: 0, width: 300, height: 41)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let destination = (popup.selectedItem?.representedObject as? UUID).map(RepositoryDestination.existingGroup) ?? .newGroup
        completion(url, destination)
    }
}
