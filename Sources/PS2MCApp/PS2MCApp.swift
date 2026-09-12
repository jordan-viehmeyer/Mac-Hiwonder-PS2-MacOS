import PS2MCKit
import SwiftUI

@main
struct PS2MCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("ps2mc", id: "main") {
            MainView().environmentObject(model)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Open Config Folder") { model.revealConfigInFinder() }
            }
        }

        // A menu bar item matters more than usual for a driver: it is running while you are
        // in a full-screen game, where the window is unreachable and the one control you
        // actually need is "mute this before I alt-tab".
        MenuBarExtra("ps2mc", systemImage: menuIcon) {
            Text(model.isRunning
                 ? (model.status.connected ? "Connected" : "Waiting for controller")
                 : "Stopped")
            Divider()
            Button(model.isRunning ? "Stop Driver" : "Start Driver") { model.toggleRunning() }
                .disabled(!model.canRun && !model.isRunning)
            if model.isRunning {
                Button(model.status.suspended ? "Resume Output" : "Mute Output") {
                    model.setSuspended(!model.status.suspended)
                }
            }
            Divider()
            Button("Open Window") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            }
            Button("Quit ps2mc") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    /// The menu bar icon is the only feedback available in a full-screen game, so the
    /// three states have to be distinguishable at a glance.
    private var menuIcon: String {
        guard model.isRunning else { return "gamecontroller" }
        return model.status.suspended ? "gamecontroller.circle" : "gamecontroller.fill"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the window leaves the driver running in the menu bar, which is the point.
        false
    }

    // Stopping the driver on quit is handled by AppModel, which owns it and knows what is
    // actually held. A fresh EventSynth here would have no state to release.
}
