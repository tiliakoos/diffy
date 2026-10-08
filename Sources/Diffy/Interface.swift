import SwiftUI

/// Switch between the pre-0.10 interface and the refreshed one while the latter settles.
/// Temporary: once the new interface is nailed down, delete this file's wrappers and the
/// classic views (`PopoverContentView`, `MainView`, `GroupColorEditor`, `GlassSettings`).
enum Interface: String {
    case modern
    case classic

    static let key = "DiffyInterface"

    static var current: Interface {
        Interface(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .modern
    }
}

/// Root of the manager window; swaps between the two windows live and tells the controller how
/// to draw the window (its title, and opaque or glass).
struct MainRootView: View {
    @ObservedObject var store: DiffyStore
    let onPresentationChange: (AppearanceMode, Interface) -> Void

    @AppStorage(Interface.key) private var interface: Interface = .modern
    @AppStorage(GlassPrefs.modeKey) private var appearanceMode: AppearanceMode = .standard

    var body: some View {
        Group {
            switch interface {
            case .modern:
                ManagerView(store: store)
            case .classic:
                MainView(store: store)
            }
        }
        .onChange(of: interface) { _, _ in
            onPresentationChange(appearanceMode, interface)
        }
        .onChange(of: appearanceMode) { _, _ in
            onPresentationChange(appearanceMode, interface)
        }
    }
}

/// Root of each status item's popover; swaps between the two popovers live.
struct PopoverRootView: View {
    @ObservedObject var store: DiffyStore
    let groupID: UUID
    let onOpenWindow: () -> Void
    let onClose: () -> Void

    @AppStorage(Interface.key) private var interface: Interface = .modern

    var body: some View {
        switch interface {
        case .modern:
            PopoverView(store: store, groupID: groupID, onOpenWindow: onOpenWindow, onClose: onClose)
        case .classic:
            PopoverContentView(store: store, groupID: groupID, onOpenWindow: onOpenWindow, onClose: onClose)
        }
    }
}
