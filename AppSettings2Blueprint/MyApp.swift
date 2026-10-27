import JTKit
import SwiftUI

@main struct MyApp: App {
    @State private var model = AppModel.forLaunch()

    var body: some Scene {
        Window("AppSettings2Blueprint", id: WindowID.main) {
            ContentView()
                .environment(model)
                .environment(model.updates)
                .frame(minWidth: 900, minHeight: 560)
                // A sandbox run (UI tests) makes no public lookups.
                .task { if !model.demo.isSandbox { await model.updates.checkAutomatically() } }
        }
        .environment(model.demo)
        .defaultSize(width: 1280, height: 800)
        .commands {
            AppCommands(model: model)
        }

        AboutWindow(configuration: .appSettings2Blueprint)
            .environment(model.demo)

        // JTKit's shared activity log (Window › Activity Log, ⇧⌘L).
        ActivityLogWindow(
            log: model.activityLog,
            emptyDescription: "Sign-ins, Jamf API calls, retries and App Store lookups appear here as they happen."
        )
        .environment(model.demo)

        // JTKit's Settings window: General (Appearance), Connections, Updates.
        SettingsWindow(updates: model.updates, opensTabsByName: true) {
            ConnectionsTab()
                .environment(model)
        }
        .environment(model.demo)
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
            selection: profileSelection(model),
            itemTitle: \.menuTitle
        ) {
            DemoModeToggle(demo: model.demo)
        }
        CommandGroup(after: .toolbar) {
            Button("Refresh Blueprints") { model.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isListing)
        }
    }
}
