import RunningOutCore
import SwiftUI

/// The Settings window (2-3 frontend-components `SettingsView`).
public struct SettingsView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) { self.model = model }

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in Task { await model.update { $0[keyPath: keyPath] = value } } })
    }

    public var body: some View {
        Form {
            Section {
                Toggle(isOn: binding(\.notifyBeforeExpiry)) {
                    Text("Notify me before a cache expires", bundle: .module)
                }
                Picker(selection: binding(\.notifyLeadMinutes)) {
                    ForEach(AppSettings.leadChoices, id: \.self) { minutes in
                        Text("\(minutes) minutes before", bundle: .module).tag(minutes)
                    }
                } label: {
                    Text("Notify", bundle: .module)
                }
                .disabled(!model.settings.notifyBeforeExpiry)
                if model.settings.notifyBeforeExpiry, model.notificationAuthorization == .denied {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(
                            "Notifications for Tokens Are Running Out are turned off in System Settings.",
                            bundle: .module)
                        Button {
                            model.openNotificationSettings()
                        } label: {
                            Text("Open Notification Settings", bundle: .module)
                        }
                    }
                }
            } header: {
                Text("Notifications", bundle: .module)
            } footer: {
                Text("Sessions with a 5-minute cache appear in the list but don't send notifications.", bundle: .module)

            }

            Section {
                Picker(selection: binding(\.warningContextTokens)) {
                    ForEach(AppSettings.warningChoices, id: \.self) { tokens in
                        let count = Presentation.tokens(tokens)
                        Text("\(count) tokens of context", bundle: .module).tag(tokens)
                    }
                } label: {
                    Text("Warn about sessions with at least", bundle: .module)
                }
            } header: {
                Text("Warnings", bundle: .module)
            }

            Section {
                Picker(selection: binding(\.rebuildThresholdTokens)) {
                    ForEach(AppSettings.thresholdChoices, id: \.self) { tokens in
                        let count = Presentation.tokens(tokens)
                        Text("\(count) tokens", bundle: .module).tag(tokens)
                    }
                } label: {
                    Text("Count a call as a cache rebuild when it writes at least", bundle: .module)
                }
            } header: {
                Text("Cache rebuilds", bundle: .module)
            } footer: {
                Text(
                    "Changing this recalculates every period. The default, 50K, matches the project's reference results.",
                    bundle: .module
                )

            }

            Section {
                Toggle(
                    isOn: Binding(
                        get: { model.loginItemStatus == .enabled || model.loginItemStatus == .requiresApproval },
                        set: { model.setOpenAtLogin($0) })
                ) {
                    Text("Open at login", bundle: .module)
                }
                .disabled(model.loginItemStatus == .unavailable)
                if model.loginItemStatus == .requiresApproval {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Allow Tokens Are Running Out in Login Items to open it at login.", bundle: .module)
                        Button {
                            model.openLoginItemsSettings()
                        } label: {
                            Text("Open Login Items Settings", bundle: .module)
                        }
                    }
                }
            } header: {
                Text("General", bundle: .module)
            }

            Section {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
                Text("Tokens Are Running Out \(version)", bundle: .module)
                Text(
                    "Reads Claude Code's history without changing it and sends nothing over the network.",
                    bundle: .module
                )

                Button {
                    model.openSource()
                } label: {
                    Text("View Source on GitHub", bundle: .module)
                }
            } header: {
                Text("About", bundle: .module)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .task { await model.refreshSystemStatus() }
    }
}
