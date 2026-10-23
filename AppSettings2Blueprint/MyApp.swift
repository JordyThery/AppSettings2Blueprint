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

        Window("About AppSettings2Blueprint", id: WindowID.about) {
            AboutView()
                .environment(model.updates)
                .frame(width: 600, height: 640)
        }
        .windowResizability(.contentSize)

        Window("Request Log", id: WindowID.requestLog) {
            RequestLogView()
                .environment(model)
        }
        .defaultSize(width: 1000, height: 650)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

enum WindowID {
    static let main = "main"
    static let about = "about"
    static let requestLog = "request-log"
}

private struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About AppSettings2Blueprint") { openWindow(id: WindowID.about) }
        }
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                // The update sheet is presented on the main window.
                openWindow(id: WindowID.main)
                model.updates.checkManually()
            }
        }
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
