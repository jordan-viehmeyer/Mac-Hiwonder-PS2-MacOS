import AppKit
import PS2MCKit
import SwiftUI

/// Captures the next key press, mouse button or scroll from inside our own window.
///
/// Uses a *local* event monitor, which only sees events already delivered to this app.
/// That is deliberate: a global monitor would read every keystroke on the machine and
/// require Accessibility, which the wizard has no business demanding just to ask the user
/// which key they want.
@MainActor
final class KeyCapture: ObservableObject {
    @Published var capturing = false
    @Published var lastSpec: String?

    private var monitor: Any?
    private var onCapture: ((String) -> Void)?

    func begin(_ handler: @escaping (String) -> Void) {
        stop()
        onCapture = handler
        capturing = true
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            guard let self, let spec = Self.spec(for: event) else { return event }
            self.lastSpec = spec
            self.onCapture?(spec)
            self.stop()
            return nil       // swallow it, so the key does not also reach the UI
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        capturing = false
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    /// Translate an AppKit event into a binding string.
    private static func spec(for event: NSEvent) -> String? {
        switch event.type {
        case .leftMouseDown: return "mouse:left"
        case .rightMouseDown: return "mouse:right"
        case .otherMouseDown: return "mouse:middle"
        case .scrollWheel:
            guard event.scrollingDeltaY != 0 else { return nil }
            return event.scrollingDeltaY > 0 ? "scroll:up" : "scroll:down"
        case .keyDown:
            guard let name = Keycodes.name(for: CGKeyCode(event.keyCode)) else { return nil }
            // Modifiers held alongside another key become a combo; a modifier pressed on
            // its own is a plain key, which is what sneak and sprint want.
            var parts: [String] = []
            let flags = event.modifierFlags
            if flags.contains(.command) { parts.append("command") }
            if flags.contains(.control) { parts.append("control") }
            if flags.contains(.option) { parts.append("option") }
            if flags.contains(.shift) { parts.append("shift") }
            let isBareModifier = ["shift", "control", "option", "command"].contains(name)
            if parts.isEmpty || isBareModifier { return "key:\(name)" }
            return "combo:\(parts.joined(separator: "+"))+\(name)"
        default:
            return nil
        }
    }
}
