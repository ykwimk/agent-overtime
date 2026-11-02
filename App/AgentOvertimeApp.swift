import SwiftUI

@main
struct AgentOvertimeApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var model = AppModel.forThisProcess()

    var body: some Scene {
        Window("Agent Overtime", id: "office") {
            OfficeView().environmentObject(model)
        }
        .defaultSize(width: OfficeView.defaultSize.width, height: OfficeView.defaultSize.height)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(model: model) }

        Window("Welcome to Agent Overtime", id: "welcome") {
            WelcomeView().environmentObject(model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Settings", id: "settings") {
            SettingsView().environmentObject(model)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Closing the office keeps the app (and its menu bar status) running.
/// No document types, URL schemes, services or launch arguments: nothing outside can ask for a command.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct AppCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openWindow(id: "settings") }.keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button("Open Office") { openWindow(id: "office") }.keyboardShortcut("o")
            Button("Start Work") {
                model.startWork()
                if model.sheet != nil || model.askAnother { openWindow(id: "office") }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Connect…") { openWindow(id: "welcome") }
        }
        // The View menu, as in other Mac apps. ⌘= works for Zoom In too (KeyboardNavigation).
        CommandGroup(before: .toolbar) {
            Button("Actual Size") { model.zoom = .normal }.keyboardShortcut("0")
            Button("Zoom In") { model.zoomIn() }.keyboardShortcut("+").disabled(model.zoom.bigger == nil)
            Button("Zoom Out") { model.zoomOut() }.keyboardShortcut("-").disabled(model.zoom.smaller == nil)
            Divider()
        }
    }
}
