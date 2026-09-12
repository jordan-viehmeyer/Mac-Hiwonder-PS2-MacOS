import CoreGraphics
import Foundation

/// Posts synthetic keyboard and mouse events.
///
/// Everything goes out through one `CGEventSource` so the window server treats the driver
/// as a single coherent input device. Events are posted at `.cghidEventTap`, the lowest
/// public insertion point, which is what Minecraft's GLFW backend sees.
public final class EventSynth {
    private let source: CGEventSource?
    /// Modifier flags currently held down by *us*, so every event we post carries them.
    private var heldFlags: CGEventFlags = []
    /// Mouse buttons we are holding, needed to keep drag events coherent.
    private var heldMouseButtons: Set<MouseButtonID> = []

    /// Our own idea of where the pointer is, in sub-pixel precision.
    ///
    /// Re-reading the system cursor each tick does not work: the window server does not
    /// reflect our own posted motion by the time the next tick asks for it. Measured at
    /// 125 Hz, only 3 of 200 posted 1 px moves were visible in the next read, so the
    /// target position was recomputed from a location that never advanced and the motion
    /// was lost. Dead-reckoning also keeps the read — which can block for tens of
    /// milliseconds — out of the hot path entirely.
    ///
    /// `nil` means we are not driving; the next motion re-seeds from the real cursor, so
    /// moving the physical mouse in between is picked up rather than fought.
    private var virtualPosition: CGPoint?

    /// Sub-pixel motion owed to the integer delta field.
    ///
    /// The window server truncates `mouseEventDeltaX/Y` to whole pixels — a posted 0.25
    /// arrives as 0 — so the remainder is carried and spent once it reaches a whole pixel.
    /// Absolute position has no such limit and advances fractionally on every tick.
    private var deltaResidual = (x: 0.0, y: 0.0)

    public init() {
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

    public func keyDown(_ code: CGKeyCode, flags: CGEventFlags = []) {
        // A modifier used as a plain key must also raise its own flag, otherwise the
        // receiving app sees a bare keycode with no modifier state and ignores it.
        heldFlags.insert(flags)
        heldFlags.insert(Self.implicitFlag(for: code))
        post(keyCode: code, down: true)
    }

    public func keyUp(_ code: CGKeyCode, flags: CGEventFlags = []) {
        post(keyCode: code, down: false)
        heldFlags.subtract(flags)
        heldFlags.subtract(Self.implicitFlag(for: code))
    }

    public func keyTap(_ code: CGKeyCode, flags: CGEventFlags = []) {
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

    public func mouseDown(_ button: MouseButtonID) {
        heldMouseButtons.insert(button)
        postMouse(button: button, type: Self.downType(button))
    }

    public func mouseUp(_ button: MouseButtonID) {
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
        // Prefer our own position: while we are driving, the system's copy lags behind.
        let location = virtualPosition ?? (CGEvent(source: nil)?.location ?? .zero)
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: location, mouseButton: button.cgButton)
        else { return }
        event.flags = heldFlags
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Mouse motion

    /// Move the pointer by a fractional delta.
    ///
    /// Minecraft (via GLFW) disables the cursor while you are in-world, which makes the
    /// game read `deltaX`/`deltaY` off the event rather than the absolute cursor position.
    /// So the delta fields are set explicitly — posting only a new absolute location would
    /// move the system cursor but leave the camera perfectly still.
    ///
    /// Callers pass real-valued motion and this handles the quantisation: the absolute
    /// position advances by the exact fraction, while the integer-only delta field is fed
    /// from a running remainder so slow pans still resolve instead of rounding to nothing.
    ///
    /// While a mouse button is held the event type must be the matching *drag* type, or
    /// the click-and-hold that Minecraft uses for mining is cancelled mid-swing.
    public func moveMouse(deltaX: Double, deltaY: Double) {
        guard deltaX != 0 || deltaY != 0 else {
            // At rest, hand the cursor back: the next motion re-seeds from wherever the
            // real mouse left it.
            virtualPosition = nil
            deltaResidual = (0, 0)
            return
        }

        var position = virtualPosition ?? (CGEvent(source: nil)?.location ?? .zero)
        position.x += deltaX
        position.y += deltaY
        position = Self.clamped(position)
        virtualPosition = position

        let rawX = deltaX + deltaResidual.x
        let rawY = deltaY + deltaResidual.y
        let stepX = rawX.rounded(.towardZero)
        let stepY = rawY.rounded(.towardZero)
        deltaResidual = (rawX - stepX, rawY - stepY)

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
                                  mouseCursorPosition: position, mouseButton: button)
        else { return }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(stepX))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(stepY))
        event.flags = heldFlags
        event.post(tap: .cghidEventTap)
    }

    /// Keep the dead-reckoned position on a real display.
    ///
    /// Nothing corrects our position while we are driving, so without this a long push
    /// against the edge of the screen would walk it arbitrarily far into empty coordinate
    /// space, and the cursor would then take just as long to come back.
    private static func clamped(_ point: CGPoint) -> CGPoint {
        var bounds = CGRect.null
        var count: UInt32 = 0
        if CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 {
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            if CGGetActiveDisplayList(count, &ids, &count) == .success {
                for id in ids.prefix(Int(count)) {
                    bounds = bounds.union(CGDisplayBounds(id))
                }
            }
        }
        guard !bounds.isNull, !bounds.isEmpty else { return point }
        return CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX - 1),
                       y: min(max(point.y, bounds.minY), bounds.maxY - 1))
    }

    /// Forget the dead-reckoned position, so the next motion re-seeds from the real cursor.
    public func releaseCursor() {
        virtualPosition = nil
        deltaResidual = (0, 0)
    }

    // MARK: - Scroll

    public func scroll(_ direction: ScrollDirection, amount: Int32) {
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
    public func releaseAll(keys: [CGKeyCode]) {
        for button in heldMouseButtons { mouseUp(button) }
        heldMouseButtons.removeAll()
        for code in keys { post(keyCode: code, down: false) }
        heldFlags = []
        releaseCursor()
    }
}
