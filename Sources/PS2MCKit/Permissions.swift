import AppKit
import CoreGraphics
import Foundation
import IOKit.hid

/// The two TCC grants this driver needs, and how to ask for them.
///
/// They are separate and independently revocable, and the failure modes look nothing alike:
/// without Input Monitoring the controller reads as permanently idle, while without
/// Accessibility the sticks read fine but nothing reaches the game.
///
/// Each is checked through the API that asks the question we actually care about:
///
///   - `CGPreflightPostEventAccess` — "may I post synthetic events", rather than
///     `AXIsProcessTrusted`, which answers the adjacent question "am I an assistive
///     client" and is known to cache its answer for the life of the process. Caching is
///     what makes a freshly granted permission appear to be ignored until relaunch.
///   - `IOHIDCheckAccess` plus `CGPreflightListenEventAccess` for reading the pad. The
///     former reports `unknown` for a process that has never touched HID, which is not the
///     same as denied; the cross-check resolves that limbo instead of showing a warning
///     for a permission that is in fact fine.
public enum Permissions {
    public enum Status: Equatable {
        case granted
        /// Explicitly refused, or revoked in System Settings.
        case denied
        /// Never evaluated for this binary. The first attempt will prompt.
        case notDetermined

        public var isGranted: Bool { self == .granted }
        /// Whether it is worth trying: a permission that has never been evaluated may
        /// simply prompt and succeed, so it must not block the attempt.
        public var blocksUse: Bool { self == .denied }
    }

    /// Needed to *read* the gamepad.
    public static func inputMonitoring() -> Status {
        // Either API answering "granted" is good enough; IOHIDCheckAccess alone leaves a
        // process that has not yet opened a device sitting in `unknown`.
        if CGPreflightListenEventAccess() { return .granted }
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .notDetermined
        }
    }

    /// Needed to *post* keyboard and mouse events.
    public static func accessibility() -> Status {
        if CGPreflightPostEventAccess() { return .granted }
        // Preflight says no. Distinguish "never asked" from "refused": a process that has
        // never been evaluated is not yet trusted either, so fall back to the AX check to
        // see whether the system has an opinion at all.
        return AXIsProcessTrusted() ? .granted : .denied
    }

    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        // The CG variant prompts and returns the outcome; IOHIDRequestAccess is the older
        // path and still worth calling when the newer one declines immediately.
        if CGRequestListenEventAccess() { return true }
        return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    @discardableResult
    public static func requestAccessibility() -> Bool {
        if CGRequestPostEventAccess() { return true }
        // Fall back to the AX prompt, which is the one that offers to open System Settings.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    public static func openSettings(pane: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        NSWorkspace.shared.open(url)
    }

    /// Why a permission that the user believes they granted can still read as missing.
    ///
    /// Without a Developer ID, the bundle is ad-hoc signed and its designated requirement
    /// is a bare `cdhash`. TCC stores that requirement, so a rebuild that changes the
    /// binary at all produces what the system considers a different application — the old
    /// grant stays in the list, looking correct, and applies to nothing.
    public static let staleGrantAdvice = """
        If you granted this and it still says otherwise, the entry in System Settings is \
        probably for an older build. Unsigned apps are identified by a hash of the binary, \
        so every rebuild looks like a new app. Remove the old ps2mc entry (select it, press −), \
        then add the current one back.
        """

    /// Print a report and return whether the driver can actually run.
    @discardableResult
    public static func report(requesting: Bool) -> Bool {
        func mark(_ status: Status) -> String {
            switch status {
            case .granted: return "✅ granted"
            case .denied: return "❌ not granted"
            case .notDetermined: return "⚠️  not yet requested"
            }
        }

        var input = inputMonitoring()
        if requesting, input != .granted {
            requestInputMonitoring()
            input = inputMonitoring()
        }
        var access = accessibility()
        if requesting, access != .granted {
            requestAccessibility()
            access = accessibility()
        }

        print("Permissions")
        print("  Input Monitoring (read the gamepad)   \(mark(input))")
        print("  Accessibility    (send keys & mouse)  \(mark(access))")

        let ok = input == .granted && access == .granted
        if !ok {
            let binary = ProcessInfo.processInfo.arguments.first ?? "ps2mc"
            print("""

                Grant both to whatever *launches* ps2mc — for a terminal run that is
                Terminal or iTerm, not ps2mc itself:

                  System Settings > Privacy & Security > Input Monitoring
                  System Settings > Privacy & Security > Accessibility

                \(staleGrantAdvice)

                Failing that, reset and grant again:
                  tccutil reset Accessibility
                  tccutil reset ListenEvent

                Current binary: \(binary)
                """)
        }
        return ok
    }
}
