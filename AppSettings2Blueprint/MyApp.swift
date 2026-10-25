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

        Window("Request Log", id: WindowID.requestLog) {
            RequestLogView()
                .environment(model)
        }
        .defaultSize(width: 1000, height: 650)

        // JTKit's Settings window: General (Appearance), Connections, Updates.
        SettingsWindow(updates: model.updates, opensTabsByName: true) {
            ConnectionsTab()
                .environment(model)
        }
    }
}

enum WindowID {
    static let main = "main"
    static let requestLog = "request-log"
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
        CommandGroup(after: .windowList) {
            Button("Request Log") { openWindow(id: WindowID.requestLog) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}
