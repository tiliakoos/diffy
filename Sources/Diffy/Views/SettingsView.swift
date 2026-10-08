import SwiftUI

struct SettingsView: View {
    @ObservedObject var launchAtLoginController: LaunchAtLoginController
    let updaterController: UpdaterController

    @AppStorage(Interface.key) private var interface: Interface = .modern
    @AppStorage(GlassPrefs.modeKey) private var appearanceMode: AppearanceMode = .standard
    @AppStorage(GlassPrefs.variantKey) private var glassVariant: GlassVariant = .frosted
    @AppStorage(GlassPrefs.opacityKey) private var glassOpacity: Double = GlassPrefs.defaultOpacity

    var body: some View {
        Form {
            Section {
                Picker("Interface", selection: $interface) {
                    Text("New").tag(Interface.modern)
                    Text("Classic").tag(Interface.classic)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Classic is the look before 0.10 and brings back the Apple Glass setting. The switch is temporary while the new interface settles.")
            }

            Section("General") {
                Toggle("Open at Login", isOn: launchAtLoginBinding)
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

            // Glass is a classic-only feature; the modern window follows macOS.
            if interface == .classic {
                Section("Appearance") {
                    Picker("Mode", selection: $appearanceMode) {
                        Text("Standard").tag(AppearanceMode.standard)
                        Text("Apple Glass").tag(AppearanceMode.appleGlass)
                    }
                    .pickerStyle(.segmented)

                    if appearanceMode == .appleGlass {
                        Picker("Glass Style", selection: $glassVariant) {
                            Text("Frosted").tag(GlassVariant.frosted)
                            Text("Clear").tag(GlassVariant.clear)
                        }
                        .pickerStyle(.segmented)

                        LabeledContent("Opacity") {
                            Slider(value: $glassOpacity, in: GlassPrefs.opacityRange)
                        }
                    }
                }
            }

            Section("Updates") {
                LabeledContent("Diffy \(Self.versionString)") {
                    Button("Check for Updates…") {
                        updaterController.checkForUpdates()
                    }
                    .disabled(!updaterController.canCheckForUpdates)
                }
                Text(updaterController.canCheckForUpdates
                     ? "Updates install automatically when one is available."
                     : "Updates install through Homebrew: brew upgrade --cask diffy")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
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
        return "\(version) (\(build))"
    }()
}
