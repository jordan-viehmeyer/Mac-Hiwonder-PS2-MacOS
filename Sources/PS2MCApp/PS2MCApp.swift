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
                Button("Reveal Profile in Finder") { model.revealProfilesInFinder() }
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--render-docs <dir>` produces the README screenshots and quits. Hidden rather
        // than advertised: it exists for the build, not for users.
        let args = CommandLine.arguments

        // `--render-docs <dir>` writes the pure-SwiftUI diagram, which ImageRenderer
        // handles faithfully, and quits.
        if let flag = args.firstIndex(of: "--render-docs"), flag + 1 < args.count {
            MainActor.assumeIsolated {
                DocsRenderer.run(into: URL(fileURLWithPath: args[flag + 1]))
            }
            NSApp.terminate(nil)
            return
        }

        // `--diagnose-permissions` prints what the TCC APIs report for this bundle over
        // several seconds, then quits. Diagnosing "it says I have not granted it" needs
        // the app's own identity, not a terminal's.
        if args.contains("--diagnose-permissions") {
            print("bundle: \(Bundle.main.bundleIdentifier ?? "none")")
            print("path:   \(Bundle.main.bundlePath)")
            for i in 0..<8 {
                let hid = Permissions.inputMonitoring()
                let ax = Permissions.accessibility()
                print(String(format: "t=%.1fs  InputMonitoring=%@  Accessibility=%@",
                             Double(i) * 0.5, "\(hid)", "\(ax)"))
                usleep(500_000)
            }
            NSApp.terminate(nil)
            return
        }

        // `--docs-pose <view>` shows one view at a known rect for an external capture.
        if DocsRenderer.posed != nil {
            let tall = ["tuning", "wizard", "calibration"].contains(DocsRenderer.posed!)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                MainActor.assumeIsolated {
                    DocsRenderer.poseWindow(
                        size: CGSize(width: 760, height: tall ? 860 : 780))
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the window leaves the driver running in the menu bar, which is the point.
        false
    }

    // Stopping the driver on quit is handled by AppModel, which owns it and knows what is
    // actually held. A fresh EventSynth here would have no state to release.
}
