import AppKit
import CoreGraphics
import Foundation
import IOKit.hid

/// The two TCC grants this driver needs, and how to ask for them.
///
/// They are separate and independently revocable, and the failure modes look nothing alike:
/// without Input Monitoring the controller reads as permanently idle, while without
/// Accessibility the sticks read fine but nothing reaches the game. Checking both up front
/// turns two confusing silences into one actionable message.
public enum Permissions {
    public enum Status {
        case granted
        case denied
        case unknown
    }

    /// Needed to *read* the gamepad.
    public static func inputMonitoring() -> Status {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .unknown
        }
    }

    /// Needed to *post* keyboard and mouse events.
    public static func accessibility(prompt: Bool = false) -> Status {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt]
        return AXIsProcessTrustedWithOptions(options as CFDictionary) ? .granted : .denied
    }

    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    public static func openSettings(pane: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        NSWorkspace.shared.open(url)
    }

    /// Print a report and return whether the driver can actually run.
    @discardableResult
    public static func report(requesting: Bool) -> Bool {
        func mark(_ status: Status) -> String {
            switch status {
            case .granted: return "✅ granted"
            case .denied: return "❌ not granted"
            case .unknown: return "⚠️  not determined"
            }
        }

        var input = inputMonitoring()
        if requesting, input != .granted {
            requestInputMonitoring()
            input = inputMonitoring()
        }
        var access = accessibility(prompt: requesting)
        if requesting, access != .granted {
            access = accessibility(prompt: false)
        }

        print("Permissions")
        print("  Input Monitoring (read the gamepad)   \(mark(input))")
        print("  Accessibility    (send keys & mouse)  \(mark(access))")

        let ok = input == .granted && access == .granted
        if !ok {
            let binary = ProcessInfo.processInfo.arguments.first ?? "ps2mc"
            print("""

                Grant both to the app that *launches* ps2mc — for a terminal run that is
                Terminal or iTerm, not ps2mc itself:

                  System Settings > Privacy & Security > Input Monitoring
                  System Settings > Privacy & Security > Accessibility

                macOS caches these per binary path. If you rebuild ps2mc to a new location,
                or the toggle is already on but nothing works, switch it off and on again:

                  tccutil reset Accessibility
                  tccutil reset ListenEvent

                Current binary: \(binary)
                """)
        }
        return ok
    }
}
