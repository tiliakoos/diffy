import SwiftUI

struct SettingsView: View {
    @ObservedObject var launchAtLoginController: LaunchAtLoginController
    let updaterController: UpdaterController

    @AppStorage(GlassPrefs.variantKey) private var glassVariant: GlassVariant = .frosted
    @AppStorage(GlassPrefs.opacityKey) private var glassOpacity: Double = GlassPrefs.defaultOpacity

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at Login", isOn: launchAtLoginBinding)
                    .toggleStyle(.switch)

                if let error = launchAtLoginController.lastError {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .font(.caption)
                }
            }

            Section("Appearance") {
                Picker("Glass Style", selection: $glassVariant) {
                    Text("Frosted").tag(GlassVariant.frosted)
                    Text("Clear").tag(GlassVariant.clear)
                }
                .pickerStyle(.segmented)

                LabeledContent("Opacity") {
                    Slider(value: $glassOpacity, in: GlassPrefs.opacityRange)
                }
            }

            Section("Updates") {
                HStack {
                    Button("Check for Updates…") {
                        updaterController.checkForUpdates()
                    }
                    .disabled(!updaterController.canCheckForUpdates)

                    if !updaterController.canCheckForUpdates {
                        Text("Updates are unavailable in this build.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Version") {
                    Text(Self.versionString)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .onAppear {
            launchAtLoginController.refresh()
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding {
            launchAtLoginController.isEnabled
        } set: { newValue in
            launchAtLoginController.setEnabled(newValue)
        }
    }

    private static let versionString: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(build))"
    }()
}
