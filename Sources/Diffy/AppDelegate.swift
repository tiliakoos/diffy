import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = DiffyStore()
    let launchAtLoginController = LaunchAtLoginController()
    let updaterController = UpdaterController()

    private var statusItemManager: StatusItemManager?
    private var mainWindowController: MainWindowController?

    private static let hasLaunchedBeforeKey = "DiffyHasLaunchedBefore"

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.load()

        mainWindowController = MainWindowController(store: store)

        statusItemManager = StatusItemManager(store: store) { [weak self] in
            self?.mainWindowController?.show()
        }

        store.start()

        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.hasLaunchedBeforeKey) == false {
            defaults.set(true, forKey: Self.hasLaunchedBeforeKey)
            mainWindowController?.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }
}
