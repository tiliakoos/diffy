import AppKit
import Combine
import DiffyCore
import os
import SwiftUI

private let statusItemLog = Logger(subsystem: "com.nickt.diffy", category: "statusItem")

@MainActor
final class StatusItemManager: NSObject {
    private let store: DiffyStore
    private let onOpenWindow: () -> Void
    private var cancellables: Set<AnyCancellable> = []
    private var popoverDismissObservers: [NSObjectProtocol] = []
    private var globalMouseMonitor: Any?
    private var items: [UUID: GroupStatusItem] = [:]
    private var groupOrder: [UUID] = []
    /// Window frame from before the first badge change of a burst, kept until the placement check runs.
    private var placementBaselines: [UUID: CGRect] = [:]
    private var placementChecks: [UUID: Task<Void, Never>] = [:]
    private var lastRecoveryRebuild: Date?

    init(store: DiffyStore, onOpenWindow: @escaping () -> Void) {
        self.store = store
        self.onOpenWindow = onOpenWindow
        super.init()

        installPopoverDismissObservers()

        store.$groups
            .combineLatest(store.$repositories, store.$summaries)
            .sink { [weak self] groups, repositories, summaries in
                self?.update(groups: groups, repositories: repositories, summaries: summaries)
            }
            .store(in: &cancellables)

        // The badge style follows the interface setting, which the store knows nothing about.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.update(groups: self.store.groups, repositories: self.store.repositories, summaries: self.store.summaries)
            }
            .store(in: &cancellables)
    }

    private func update(
        groups: [RepositoryGroup],
        repositories: [RepositoryConfig],
        summaries: [UUID: RepoDiffSummary]
    ) {
        let desiredOrder = groups.filter { !$0.isHidden }.map { $0.id }

        if desiredOrder != groupOrder {
            // If the new order is the current order with some entries removed
            // (i.e. pure deletion / hide), only tear down the gone items so the
            // surviving icons don't flicker. Any reorder or addition falls back
            // to a full rebuild because AppKit appends new status items to the end.
            let isPureDeletion = groupOrder.filter { desiredOrder.contains($0) } == desiredOrder

            if isPureDeletion {
                let removed = Set(groupOrder).subtracting(desiredOrder)
                for id in removed {
                    if let item = items[id] {
                        NSStatusBar.system.removeStatusItem(item.statusItem)
                        items.removeValue(forKey: id)
                    }
                    cancelPlacementCheck(id)
                }
            } else {
                for (id, item) in items {
                    NSStatusBar.system.removeStatusItem(item.statusItem)
                    cancelPlacementCheck(id)
                }
                items.removeAll(keepingCapacity: true)
                for group in groups where !group.isHidden {
                    items[group.id] = makeStatusItem(for: group)
                }
            }

            groupOrder = desiredOrder
        }

        let interface = Interface.current
        for group in groups {
            guard var item = items[group.id] else { continue }
            let visibleRepos = repositories.filter { $0.groupID == group.id && !$0.isHidden }
            var added = 0
            var removed = 0
            var errorCount = 0
            for repo in visibleRepos {
                if let summary = summaries[repo.id] {
                    added += summary.addedLines
                    removed += summary.removedLines
                    if summary.errorMessage != nil { errorCount += 1 }
                }
            }

            let displayName = group.name.isEmpty ? "Diffy" : group.name
            let hasError = errorCount > 0
            let newState = BadgeState(
                displayName: displayName,
                added: added,
                removed: removed,
                visibleRepoCount: visibleRepos.count,
                colors: group.diffColors,
                badgeLabel: group.badgeLabel,
                errorCount: errorCount,
                interface: interface
            )

            if item.lastBadgeState != newState {
                if let button = item.statusItem.button {
                    let frameBefore = button.window?.frame
                    button.title = ""
                    button.image = BadgeRenderer.image(
                        added: added,
                        removed: removed,
                        colors: group.diffColors,
                        badgeLabel: group.badgeLabel,
                        hasError: hasError,
                        interface: interface
                    )
                    button.imagePosition = .imageOnly
                    var tip = "\(displayName) — \(visibleRepos.count) visible \(visibleRepos.count == 1 ? "repo" : "repos")"
                    if errorCount > 0 {
                        tip += " (\(errorCount) with errors)"
                    }
                    button.toolTip = tip
                    let counts = added == 0 && removed == 0 ? "no changes" : "\(added) lines added, \(removed) removed"
                    button.setAccessibilityLabel("\(displayName), \(counts)" + (hasError ? ", \(errorCount) with errors" : ""))
                    // The first render has no placed frame to compare against.
                    if item.lastBadgeState != nil, let frameBefore {
                        schedulePlacementCheck(groupID: group.id, frameBefore: frameBefore)
                    }
                }
                item.lastBadgeState = newState
                items[group.id] = item
            }
        }
    }

    // MARK: - Placement check

    // macOS 27 lays the menu bar out in MenuBarAgent. When a badge changes width, AppKit resizes the
    // item at once and MenuBarAgent moves it into its new slot about 0.1 s later. On 2026-10-31 that
    // second step was lost once: the badge drew at its new width from its old position, over the next
    // group's pill, until it changed width again. A second after each change Diffy checks that the
    // item moved; if not it nudges the length, and if that doesn't take it rebuilds the items.

    private func schedulePlacementCheck(groupID: UUID, frameBefore: CGRect) {
        // A later change in the same burst may land mid-layout; keep the frame from before the first.
        if placementBaselines[groupID] == nil {
            placementBaselines[groupID] = frameBefore
        }
        placementChecks[groupID]?.cancel()
        placementChecks[groupID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.checkPlacement(groupID: groupID, afterNudge: false)
        }
    }

    private func cancelPlacementCheck(_ groupID: UUID) {
        placementChecks.removeValue(forKey: groupID)?.cancel()
        placementBaselines.removeValue(forKey: groupID)
    }

    private func checkPlacement(groupID: UUID, afterNudge: Bool) {
        let name = store.groups.first { $0.id == groupID }?.name ?? ""
        guard
            let baseline = placementBaselines[groupID],
            let item = items[groupID],
            let frame = item.statusItem.button?.window?.frame
        else {
            cancelPlacementCheck(groupID)
            return
        }

        guard StatusItemPlacement.wasLeftInPlace(before: baseline, after: frame) else {
            if afterNudge {
                statusItemLog.notice("\(name, privacy: .public): the nudge moved the badge into place")
            } else {
                statusItemLog.debug("\(name, privacy: .public): badge placed, x \(Int(baseline.minX)) → \(Int(frame.minX)), width \(Int(baseline.width)) → \(Int(frame.width))")
            }
            cancelPlacementCheck(groupID)
            return
        }

        // Still stuck within 10 minutes of a rebuild means something systematic (or a misread frame):
        // stop poking until then rather than nudging on every badge change.
        if let lastRecoveryRebuild, Date().timeIntervalSince(lastRecoveryRebuild) < 600 {
            statusItemLog.debug("\(name, privacy: .public): badge left in place again within 10 minutes of a rebuild; leaving it")
            cancelPlacementCheck(groupID)
            return
        }

        if !afterNudge {
            statusItemLog.notice("\(name, privacy: .public): badge changed width \(Int(baseline.width)) → \(Int(frame.width)) but its left edge stayed at x \(Int(baseline.minX)) → \(Int(frame.minX)); nudging its length")
            // Two real length changes, in separate transactions, ask MenuBarAgent for a fresh layout.
            // `length` excludes the menu bar's padding, so the image width + 1 is a 1 pt nudge.
            let statusItem = item.statusItem
            statusItem.length = (statusItem.button?.image?.size.width ?? 0) + 1
            placementChecks[groupID] = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                // Restore even when cancelled: a fixed length would stop the badge from fitting later counts.
                statusItem.length = NSStatusItem.variableLength
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.checkPlacement(groupID: groupID, afterNudge: true)
            }
            return
        }

        cancelPlacementCheck(groupID)
        statusItemLog.notice("\(name, privacy: .public): the nudge didn't move the badge; rebuilding the menu-bar items")
        lastRecoveryRebuild = Date()
        for other in items.values where other.popover.isShown {
            other.popover.performClose(nil)
        }
        groupOrder = []  // forces update() down its full-rebuild path
        update(groups: store.groups, repositories: store.repositories, summaries: store.summaries)
    }

    private func makeStatusItem(for group: RepositoryGroup) -> GroupStatusItem {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let popover = NSPopover()
        popover.behavior = .transient
        let hosting = NSHostingController(
            rootView: PopoverRootView(
                store: store,
                groupID: group.id,
                onOpenWindow: { [weak self, weak popover] in
                    popover?.performClose(nil)
                    self?.onOpenWindow()
                },
                onClose: { [weak popover] in
                    popover?.performClose(nil)
                }
            )
        )
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        let handler = StatusItemClickHandler { [weak self] event in
            self?.handleClick(groupID: group.id, event: event)
        }

        statusItem.button?.target = handler
        statusItem.button?.action = #selector(StatusItemClickHandler.handle(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        return GroupStatusItem(
            statusItem: statusItem,
            popover: popover,
            clickHandler: handler,
            lastBadgeState: nil
        )
    }

    private func handleClick(groupID: UUID, event: NSEvent?) {
        guard let item = items[groupID] else { return }
        guard let event = event ?? NSApp.currentEvent else {
            togglePopover(groupID: groupID, item: item)
            return
        }

        if event.type == .rightMouseUp {
            showContextMenu(for: item, groupID: groupID)
        } else {
            togglePopover(groupID: groupID, item: item)
        }
    }

    private func togglePopover(groupID: UUID, item: GroupStatusItem) {
        guard let button = item.statusItem.button else { return }
        if item.popover.isShown {
            item.popover.performClose(nil)
        } else {
            store.refreshLoadedRecentCommits(groupID: groupID)
            for other in items.values where other.popover.isShown {
                other.popover.performClose(nil)
            }
            NSApp.activate()
            item.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            item.popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu(for item: GroupStatusItem, groupID: UUID) {
        let menu = NSMenu()
        let open = menu.addItem(withTitle: "Open Diffy", action: #selector(menuOpen), keyEquivalent: "o")
        open.target = self
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(NSMenuItem.separator())
        let name = store.groups.first { $0.id == groupID }?.name ?? ""
        let hide = menu.addItem(
            withTitle: "Hide \u{201C}\(name.isEmpty ? "Diffy" : name)\u{201D} from Menu Bar",
            action: #selector(menuHide(_:)),
            keyEquivalent: ""
        )
        hide.target = self
        hide.representedObject = groupID
        menu.addItem(NSMenuItem.separator())
        let quit = menu.addItem(withTitle: "Quit Diffy", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        item.statusItem.menu = menu
        item.statusItem.button?.performClick(nil)
        item.statusItem.menu = nil
    }

    @objc private func menuOpen() {
        onOpenWindow()
    }

    @objc private func menuHide(_ sender: NSMenuItem) {
        guard let groupID = sender.representedObject as? UUID else { return }
        store.setGroupHidden(groupID, isHidden: true)
    }

    @objc private func menuSettings() {
        // The app is usually .accessory here; without activation the Settings
        // window can open behind other apps. Policy stays owned by MainWindowController.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    private func installPopoverDismissObservers() {
        popoverDismissObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard
                    let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                    app.bundleIdentifier != Bundle.main.bundleIdentifier
                else { return }
                Task { @MainActor in
                    guard let self else { return }
                    for item in self.items.values where item.popover.isShown {
                        item.popover.performClose(nil)
                    }
                }
            }
        )

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for item in self.items.values where item.popover.isShown {
                    item.popover.performClose(nil)
                }
            }
        }
    }
}

private struct GroupStatusItem {
    let statusItem: NSStatusItem
    let popover: NSPopover
    /// Required retain anchor: `NSControl.target` is non-owning, so this is the only strong
    /// reference keeping the click handler alive. Removing it silently breaks clicks (no warning).
    let clickHandler: StatusItemClickHandler
    var lastBadgeState: BadgeState?
}

enum StatusItemPlacement {
    /// A variable-length status item keeps its right edge when its width changes, so the menu bar moves
    /// its left edge by the same amount. One that changed width but kept its left edge was never laid
    /// out again: it draws at the new width from the old position. A frame at the origin or without
    /// height has not been placed yet (seen at launch), so it can't be compared.
    static func wasLeftInPlace(before: CGRect, after: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        func isPlaced(_ frame: CGRect) -> Bool { frame.height > 0 && frame.origin != .zero }
        guard isPlaced(before), isPlaced(after) else { return false }
        return abs(after.width - before.width) >= tolerance && abs(after.minX - before.minX) < tolerance
    }
}

struct BadgeState: Equatable {
    let displayName: String
    let added: Int
    let removed: Int
    let visibleRepoCount: Int
    let colors: DiffColors
    let badgeLabel: BadgeLabel?
    let errorCount: Int
    let interface: Interface
}

@MainActor
private final class StatusItemClickHandler: NSObject {
    private let onClick: (NSEvent?) -> Void

    init(onClick: @escaping (NSEvent?) -> Void) {
        self.onClick = onClick
    }

    @objc func handle(_ sender: Any?) {
        onClick(NSApp.currentEvent)
    }
}
