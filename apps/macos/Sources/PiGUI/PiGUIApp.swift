import SwiftUI
import PiCore

@main
struct PiGUIApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Thread") {
                    NotificationCenter.default.post(name: .piNewThread, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Open Folder…") {
                    NotificationCenter.default.post(name: .piOpenFolder, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandGroup(after: .sidebar) {
                Button("Toggle Diff Panel") {
                    NotificationCenter.default.post(name: .piToggleDiff, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)

                Button("Toggle Terminal") {
                    NotificationCenter.default.post(name: .piToggleTerminal, object: nil)
                }
                .keyboardShortcut("j", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

/// Menu commands are delivered as notifications so the views that own the relevant
/// state can react without the App type reaching into their internals.
extension Notification.Name {
    static let piNewThread = Notification.Name("pi.newThread")
    static let piOpenFolder = Notification.Name("pi.openFolder")
    static let piToggleDiff = Notification.Name("pi.toggleDiff")
    static let piToggleTerminal = Notification.Name("pi.toggleTerminal")
}
