import CoreGraphics
import Foundation

/// Anything that can be bound to an action. Used as the identity for press/release
/// bookkeeping so buttons, D-pad directions and stick directions all behave alike.
enum Slot: Hashable {
    case button(ButtonID)
    case dpad(DPadID)
    case move(stick: StickSide, direction: DPadID)
}

enum StickSide: String, Hashable {
    case left, right
}

/// Translates controller state into keyboard and mouse output.
///
/// Runs entirely on the HID run-loop thread: input reports and the poll timer are both
/// scheduled there, so the mutable state below needs no locking.
final class Engine {
    private let config: Config
    private let synth: EventSynth
    private let bindings: [Slot: Action]
    private let verbose: Bool

    private var state = ControllerState()
    private var lastTick = Date()

    /// Slots whose physical input is active right now.
    private var activeSlots: Set<Slot> = []
    /// Hold-mode outputs currently pressed, so they can be released on the matching edge.
    private var heldOutputs: [Slot: Action] = [:]
    /// Toggle-mode latches that are currently on.
    private var latched: Set<Slot> = []
    /// Auto-repeat schedule for `@repeat` actions.
    private var repeatDue: [Slot: Date] = [:]

    /// Hotbar slot tracked locally, only meaningful when `hotbarMode == .numbers`.
    private var hotbarSlot = 1

    /// When suspended the driver reads the pad but emits nothing, apart from the toggle
    /// itself. Gives the player a way to alt-tab or type without the stick fighting them.
    private(set) var suspended = false

    init(config: Config, synth: EventSynth, verbose: Bool, source: URL? = nil) throws {
        self.config = config
        self.synth = synth
        self.verbose = verbose

        let resolved = try config.resolveBindings(source: source)
        var table: [Slot: Action] = [:]
        for (id, action) in resolved.buttons { table[.button(id)] = action }
        for (id, action) in resolved.dpad { table[.dpad(id)] = action }
        for (side, stick) in [(StickSide.left, config.leftStick), (.right, config.rightStick)]
        where stick.role == .move {
            table[.move(stick: side, direction: .up)] = try Action.parse(stick.move.up)
            table[.move(stick: side, direction: .down)] = try Action.parse(stick.move.down)
            table[.move(stick: side, direction: .left)] = try Action.parse(stick.move.left)
            table[.move(stick: side, direction: .right)] = try Action.parse(stick.move.right)
        }
        self.bindings = table
    }

    // MARK: - Input

    func ingest(report: [UInt8]) {
        guard let decoded = ControllerState.decode(report: report, bitOrder: config.buttonBitOrder)
        else { return }
        state = decoded
    }

    /// Called when the pad disappears: drop every held key so nothing sticks.
    func handleDisconnect() {
        state = ControllerState()
        releaseEverything()
        activeSlots.removeAll()
    }

    // MARK: - Tick

    func tick() {
        let now = Date()
        let dt = min(now.timeIntervalSince(lastTick), 0.1)  // clamp after a stall
        lastTick = now
        guard state.connected else { return }

        updateLook(dt: dt)
        updateSlots()
        serviceRepeats(now: now)
    }

    // MARK: - Mouse look

    private func updateLook(dt: TimeInterval) {
        guard !suspended else { return }
        var dx = 0.0
        var dy = 0.0
        for (side, stick) in [(StickSide.left, config.leftStick), (.right, config.rightStick)]
        where stick.role == .look {
            let (x, y) = axes(for: side)
            let (cx, cy) = Engine.shape(x: x, y: y, look: stick.look)
            dx += cx * stick.look.sensitivityX * dt * (stick.look.invertX ? -1 : 1)
            dy += cy * stick.look.sensitivityY * dt * (stick.look.invertY ? -1 : 1)
        }
        synth.moveMouse(deltaX: dx, deltaY: dy)
    }

    /// Apply a radial deadzone and a response curve.
    ///
    /// The deadzone is radial rather than per-axis so that a diagonal push is not clipped
    /// into an axis-aligned one, and the magnitude is rescaled across the remaining travel
    /// so the very first movement past the deadzone is slow instead of jumping.
    static func shape(x: Double, y: Double, look: LookBinding) -> (Double, Double) {
        let magnitude = (x * x + y * y).squareRoot()
        guard magnitude > look.deadzone else { return (0, 0) }
        let normalized = min((magnitude - look.deadzone) / (1 - look.deadzone), 1)
        let curved = pow(normalized, look.exponent)
        let scale = curved / magnitude
        return (x * scale, y * scale)
    }

    private func axes(for side: StickSide) -> (Double, Double) {
        switch side {
        case .left: return (state.leftX, state.leftY)
        case .right: return (state.rightX, state.rightY)
        }
    }

    // MARK: - Digital slots

    private func updateSlots() {
        var nowActive: Set<Slot> = []
        for button in state.buttons { nowActive.insert(.button(button)) }
        for direction in state.dpad { nowActive.insert(.dpad(direction)) }
        for (side, stick) in [(StickSide.left, config.leftStick), (.right, config.rightStick)]
        where stick.role == .move {
            nowActive.formUnion(moveDirections(side: side, binding: stick.move))
        }

        for slot in nowActive.subtracting(activeSlots) { press(slot) }
        for slot in activeSlots.subtracting(nowActive) { release(slot) }
        activeSlots = nowActive
    }

    /// Convert a stick position into directional slots, with hysteresis so a stick resting
    /// near the threshold does not machine-gun the key.
    private func moveDirections(side: StickSide, binding: MoveBinding) -> Set<Slot> {
        let (x, y) = axes(for: side)
        var result: Set<Slot> = []
        let release = max(binding.threshold - binding.releaseHysteresis, 0.05)

        func evaluate(_ value: Double, negative: DPadID, positive: DPadID) {
            let negativeSlot = Slot.move(stick: side, direction: negative)
            let positiveSlot = Slot.move(stick: side, direction: positive)
            let wasNegative = activeSlots.contains(negativeSlot)
            let wasPositive = activeSlots.contains(positiveSlot)
            if value <= -(wasNegative ? release : binding.threshold) {
                result.insert(negativeSlot)
            } else if value >= (wasPositive ? release : binding.threshold) {
                result.insert(positiveSlot)
            }
        }

        // Y is negative-up in the report, matching screen coordinates.
        evaluate(y, negative: .up, positive: .down)
        evaluate(x, negative: .left, positive: .right)
        return result
    }

    // MARK: - Action dispatch

    private func press(_ slot: Slot) {
        guard let action = bindings[slot], action != .none else { return }

        // The suspend toggle is the one thing that still works while suspended.
        if case .toggleEngine = action {
            setSuspended(!suspended)
            return
        }
        guard !suspended else { return }

        switch action {
        case .key(let code, _, let flags, let mode):
            switch mode {
            case .hold:
                synth.keyDown(code, flags: flags)
                heldOutputs[slot] = action
            case .tap:
                synth.keyTap(code, flags: flags)
            case .toggle:
                if latched.contains(slot) {
                    latched.remove(slot)
                    synth.keyUp(code, flags: flags)
                    heldOutputs[slot] = nil
                } else {
                    latched.insert(slot)
                    synth.keyDown(code, flags: flags)
                    heldOutputs[slot] = action
                }
            case .repeatWhileHeld:
                synth.keyTap(code, flags: flags)
                repeatDue[slot] = Date().addingTimeInterval(config.repeatDelayMs / 1000)
            }

        case .mouse(let button, let mode):
            switch mode {
            case .hold:
                synth.mouseDown(button)
                heldOutputs[slot] = action
            case .tap:
                synth.mouseDown(button)
                synth.mouseUp(button)
            case .toggle:
                if latched.contains(slot) {
                    latched.remove(slot)
                    synth.mouseUp(button)
                    heldOutputs[slot] = nil
                } else {
                    latched.insert(slot)
                    synth.mouseDown(button)
                    heldOutputs[slot] = action
                }
            case .repeatWhileHeld:
                synth.mouseDown(button)
                synth.mouseUp(button)
                repeatDue[slot] = Date().addingTimeInterval(config.repeatDelayMs / 1000)
            }

        case .scroll(let direction, let amount):
            synth.scroll(direction, amount: amount)

        case .hotbarNext:
            stepHotbar(by: 1)
        case .hotbarPrev:
            stepHotbar(by: -1)
        case .hotbarSlot(let slotNumber):
            selectHotbar(slotNumber)

        case .toggleEngine, .none:
            break
        }
    }

    private func release(_ slot: Slot) {
        repeatDue[slot] = nil
        guard let action = heldOutputs[slot] else { return }
        // A toggle latch deliberately outlives the button release.
        if latched.contains(slot) { return }
        switch action {
        case .key(let code, _, let flags, _): synth.keyUp(code, flags: flags)
        case .mouse(let button, _): synth.mouseUp(button)
        default: break
        }
        heldOutputs[slot] = nil
    }

    private func serviceRepeats(now: Date) {
        guard !suspended else { return }
        for (slot, due) in repeatDue where now >= due {
            guard let action = bindings[slot] else { continue }
            switch action {
            case .key(let code, _, let flags, _): synth.keyTap(code, flags: flags)
            case .mouse(let button, _):
                synth.mouseDown(button)
                synth.mouseUp(button)
            default: continue
            }
            repeatDue[slot] = now.addingTimeInterval(config.repeatIntervalMs / 1000)
        }
    }

    // MARK: - Hotbar

    private func stepHotbar(by delta: Int) {
        switch config.hotbarMode {
        case .scroll:
            // Minecraft scrolls *up* to the previous slot, so a step of -1 is a wheel-up
            // notch. Letting the game own the index means this can never drift out of sync
            // with what the player sees.
            synth.scroll(delta > 0 ? .down : .up, amount: 1)
        case .numbers:
            hotbarSlot = ((hotbarSlot - 1 + delta) %% 9) + 1
            pressHotbarKey(hotbarSlot)
        }
    }

    private func selectHotbar(_ slot: Int) {
        hotbarSlot = min(max(slot, 1), 9)
        pressHotbarKey(hotbarSlot)
    }

    private func pressHotbarKey(_ slot: Int) {
        guard let code = Keycodes.code(for: String(slot)) else { return }
        synth.keyTap(code)
    }

    // MARK: - Suspend

    func setSuspended(_ value: Bool) {
        guard value != suspended else { return }
        suspended = value
        if value { releaseEverything() }
        log(value ? "⏸  suspended — output muted" : "▶️  resumed")
    }

    /// Drop every key, mouse button and latch we are responsible for.
    func releaseEverything() {
        var keys: [CGKeyCode] = []
        for (_, action) in heldOutputs {
            if case .key(let code, _, _, _) = action { keys.append(code) }
        }
        synth.releaseAll(keys: keys)
        heldOutputs.removeAll()
        latched.removeAll()
        repeatDue.removeAll()
    }

    private func log(_ message: String) {
        guard verbose else { return }
        print(message)
        fflush(stdout)
    }
}

/// Floor-modulo, so stepping below slot 1 wraps to 9 instead of going negative.
infix operator %%: MultiplicationPrecedence
func %% (lhs: Int, rhs: Int) -> Int {
    let r = lhs % rhs
    return r < 0 ? r + rhs : r
}
