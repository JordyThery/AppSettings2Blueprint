import JTKit
import SwiftUI

@main struct MyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("AppSettings2Blueprint", id: WindowID.main) {
            ContentView()
                .environment(model)
                .environment(model.updates)
                .frame(minWidth: 900, minHeight: 560)
                .task { await model.updates.checkAutomatically() }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            AppCommands(model: model)
        }

        AboutWindow(configuration: .appSettings2Blueprint)

        // JTKit's shared activity log (Window › Activity Log, ⇧⌘L).
        ActivityLogWindow(
            log: model.activityLog,
            emptyDescription: "Sign-ins, Jamf API calls, retries and App Store lookups appear here as they happen."
        )

        // JTKit's Settings window: General (Appearance), Connections, Updates.
        SettingsWindow(updates: model.updates, opensTabsByName: true) {
            ConnectionsTab()
                .environment(model)
        }
    }
}

enum WindowID {
    static let main = "main"
}

private struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        AppInfoCommands(appName: "AppSettings2Blueprint") {
            // The update sheet is presented on the main window.
            openWindow(id: WindowID.main)
            model.updates.checkManually()
        }
        // The toolbar picker's items, as JTKit's Connection menu.
        ConnectionCommands(
            store: model.profileStore.connections,
            selection: Binding(get: { model.profileStore.selectedProfileID },
                               set: { model.profileStore.selectedProfileID = $0 }),
            itemTitle: \.menuTitle
        )
        CommandGroup(after: .toolbar) {
            Button("Refresh Blueprints") { model.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isListing)
        }
    }
}
