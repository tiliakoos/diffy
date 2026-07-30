import SwiftUI

@main
struct DiffyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                launchAtLoginController: appDelegate.launchAtLoginController,
                updaterController: appDelegate.updaterController
            )
        }
    }
}
