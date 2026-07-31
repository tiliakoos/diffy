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
        window.title = "Manage Diffy"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 880, height: 560)
        let glass = Self.currentAppearanceMode() == .appleGlass
        window.isOpaque = !glass
        window.backgroundColor = glass ? .clear : .windowBackgroundColor
        let didRestoreFrame = window.setFrameAutosaveName("DiffyMainWindow.v2")
        if !didRestoreFrame {
            window.setContentSize(NSSize(width: 1080, height: 700))
            window.center()
        }

        super.init()

        window.delegate = self
        let onAppearanceModeChange: (AppearanceMode) -> Void = { [weak self] mode in
            self?.applyWindowTranslucency(for: mode)
        }
        window.contentViewController = NSHostingController(
            rootView: MainView(store: store, onAppearanceModeChange: onAppearanceModeChange)
        )
    }

    private static func currentAppearanceMode() -> AppearanceMode {
        let raw = UserDefaults.standard.string(forKey: GlassPrefs.modeKey) ?? ""
        return AppearanceMode(rawValue: raw) ?? .standard
    }

    private func applyWindowTranslucency(for mode: AppearanceMode) {
        let glass = mode == .appleGlass
        window.isOpaque = !glass
        window.backgroundColor = glass ? .clear : .windowBackgroundColor
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
