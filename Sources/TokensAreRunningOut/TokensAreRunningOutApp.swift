import RunningOutUI
import SwiftUI

@main
struct TokensAreRunningOutApp: App {
    @State private var model = AppModel(
        environment: .live(), scheduler: UserNotificationScheduler(), loginItem: MainAppLoginItem(),
        urlOpener: WorkspaceURLOpener())

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}
