import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let store: DiffyStore

    init(store: DiffyStore) {
        self.store = store

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
        window.isOpaque = false
        window.backgroundColor = .clear
        let didRestoreFrame = window.setFrameAutosaveName("DiffyMainWindow.v2")
        if !didRestoreFrame {
            window.setContentSize(NSSize(width: 1080, height: 700))
            window.center()
        }

        super.init()

        window.delegate = self
        window.contentViewController = NSHostingController(rootView: MainView(store: store))
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
