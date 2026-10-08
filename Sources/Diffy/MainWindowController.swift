import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow

    init(store: DiffyStore) {
        let initialFrame = NSRect(x: 0, y: 0, width: 1080, height: 700)
        window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 880, height: 560)
        _ = window.setFrameAutosaveName("DiffyMainWindow.v2")
        // setFrameAutosaveName returns whether the name was set, not whether a saved frame
        // existed — setFrameUsingName is the real "restored" signal for the fallback.
        let didRestoreFrame = window.setFrameUsingName("DiffyMainWindow.v2")
        if !didRestoreFrame {
            window.setContentSize(NSSize(width: 1080, height: 700))
            window.center()
        }

        super.init()

        window.delegate = self
        applyPresentation(mode: Self.currentAppearanceMode(), interface: Interface.current)
        window.contentViewController = NSHostingController(
            rootView: MainRootView(store: store) { [weak self] mode, interface in
                self?.applyPresentation(mode: mode, interface: interface)
            }
        )
    }

    private static func currentAppearanceMode() -> AppearanceMode {
        let raw = UserDefaults.standard.string(forKey: GlassPrefs.modeKey) ?? ""
        return AppearanceMode(rawValue: raw) ?? .standard
    }

    /// Glass exists only in the classic interface; the modern window is always opaque.
    private func applyPresentation(mode: AppearanceMode, interface: Interface) {
        let glass = interface == .classic && mode == .appleGlass
        window.isOpaque = !glass
        window.backgroundColor = glass ? .clear : .windowBackgroundColor
        window.title = interface == .modern ? "Diffy" : "Manage Diffy"
        window.invalidateShadow()
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}
