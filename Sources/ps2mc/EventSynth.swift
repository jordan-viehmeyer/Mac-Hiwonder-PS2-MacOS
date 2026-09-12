import CoreGraphics
import Foundation

/// Posts synthetic keyboard and mouse events.
///
/// Everything goes out through one `CGEventSource` so the window server treats the driver
/// as a single coherent input device. Events are posted at `.cghidEventTap`, the lowest
/// public insertion point, which is what Minecraft's GLFW backend sees.
final class EventSynth {
    private let source: CGEventSource?
    /// Modifier flags currently held down by *us*, so every event we post carries them.
    private var heldFlags: CGEventFlags = []
    /// Mouse buttons we are holding, needed to keep drag events coherent.
    private var heldMouseButtons: Set<MouseButtonID> = []

    init() {
        source = CGEventSource(stateID: .hidSystemState)
        if let source {
            // Without this, macOS suppresses real mouse input for ~250 ms after each
            // synthetic event — which would make the physical mouse feel broken while
            // the stick is driving the camera.
            source.localEventsSuppressionInterval = 0
            source.setLocalEventsFilterDuringSuppressionState(
                [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
                state: .eventSuppressionStateSuppressionInterval)
        }
    }

    // MARK: - Keyboard

    func keyDown(_ code: CGKeyCode, flags: CGEventFlags = []) {
        // A modifier used as a plain key must also raise its own flag, otherwise the
        // receiving app sees a bare keycode with no modifier state and ignores it.
        heldFlags.insert(flags)
        heldFlags.insert(Self.implicitFlag(for: code))
        post(keyCode: code, down: true)
    }

    func keyUp(_ code: CGKeyCode, flags: CGEventFlags = []) {
        post(keyCode: code, down: false)
        heldFlags.subtract(flags)
        heldFlags.subtract(Self.implicitFlag(for: code))
    }

    func keyTap(_ code: CGKeyCode, flags: CGEventFlags = []) {
        keyDown(code, flags: flags)
        keyUp(code, flags: flags)
    }

    private func post(keyCode: CGKeyCode, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
        else { return }
        event.flags = heldFlags
        event.post(tap: .cghidEventTap)
    }

    /// The flag a modifier keycode implies when pressed on its own.
    private static func implicitFlag(for code: CGKeyCode) -> CGEventFlags {
        switch code {
        case 0x38, 0x3C: return .maskShift
        case 0x3B, 0x3E: return .maskControl
        case 0x3A, 0x3D: return .maskAlternate
        case 0x37, 0x36: return .maskCommand
        case 0x3F: return .maskSecondaryFn
        default: return []
        }
    }

    // MARK: - Mouse buttons

    func mouseDown(_ button: MouseButtonID) {
        heldMouseButtons.insert(button)
        postMouse(button: button, type: Self.downType(button))
    }

    func mouseUp(_ button: MouseButtonID) {
        heldMouseButtons.remove(button)
        postMouse(button: button, type: Self.upType(button))
    }

    private static func downType(_ b: MouseButtonID) -> CGEventType {
        switch b {
        case .left: return .leftMouseDown
        case .right: return .rightMouseDown
        case .middle: return .otherMouseDown
        }
    }

    private static func upType(_ b: MouseButtonID) -> CGEventType {
        switch b {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        case .middle: return .otherMouseUp
        }
    }

    private func postMouse(button: MouseButtonID, type: CGEventType) {
        let location = CGEvent(source: nil)?.location ?? .zero
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: location, mouseButton: button.cgButton)
        else { return }
        event.flags = heldFlags
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Mouse motion

    /// Move the pointer by a relative delta.
    ///
    /// Minecraft (via GLFW) disables the cursor while you are in-world, which makes the
    /// game read `deltaX`/`deltaY` off the event rather than the absolute cursor position.
    /// So the delta fields are set explicitly — posting only a new absolute location would
    /// move the system cursor but leave the camera perfectly still.
    ///
    /// While a mouse button is held the event type must be the matching *drag* type, or
    /// the click-and-hold that Minecraft uses for mining is cancelled mid-swing.
    func moveMouse(deltaX: Double, deltaY: Double) {
        guard deltaX != 0 || deltaY != 0 else { return }
        let current = CGEvent(source: nil)?.location ?? .zero
        let target = CGPoint(x: current.x + deltaX, y: current.y + deltaY)

        let type: CGEventType
        let button: CGMouseButton
        if heldMouseButtons.contains(.left) {
            type = .leftMouseDragged; button = .left
        } else if heldMouseButtons.contains(.right) {
            type = .rightMouseDragged; button = .right
        } else if heldMouseButtons.contains(.middle) {
            type = .otherMouseDragged; button = .center
        } else {
            type = .mouseMoved; button = .left
        }

        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: target, mouseButton: button)
        else { return }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(deltaX.rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(deltaY.rounded()))
        event.flags = heldFlags
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Scroll

    func scroll(_ direction: ScrollDirection, amount: Int32) {
        var vertical: Int32 = 0
        var horizontal: Int32 = 0
        switch direction {
        case .up: vertical = amount
        case .down: vertical = -amount
        case .left: horizontal = amount
        case .right: horizontal = -amount
        }
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .line,
                                  wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0)
        else { return }
        event.flags = heldFlags
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Cleanup

    /// Release everything we are holding. Called on shutdown and whenever the engine is
    /// suspended, so a crash or a toggle can never leave W or a mouse button stuck down.
    func releaseAll(keys: [CGKeyCode]) {
        for button in heldMouseButtons { mouseUp(button) }
        heldMouseButtons.removeAll()
        for code in keys { post(keyCode: code, down: false) }
        heldFlags = []
    }
}
