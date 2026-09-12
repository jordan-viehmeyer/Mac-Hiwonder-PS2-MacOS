import CoreGraphics
import Foundation

/// Anything that can be bound to an action. Used as the identity for press/release
/// bookkeeping so buttons, D-pad directions and stick directions all behave alike.
public enum Slot: Hashable {
    case button(ButtonID)
    case dpad(DPadID)
    case move(stick: StickSide, direction: DPadID)
}

public enum StickSide: String, Hashable {
    case left, right
}

/// Translates controller state into keyboard and mouse output.
///
/// Runs entirely on the HID run-loop thread: input reports and the poll timer are both
/// scheduled there, so the mutable state below needs no locking.
public final class Engine {
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

    /// Low-pass state for each look stick, so the camera eases in and out of motion
    /// instead of snapping to whatever the stick reads on a single tick.
    private var lookSmoothed: [StickSide: (x: Double, y: Double)] = [:]

    /// When each move direction first fell below its release threshold. Used to hold a
    /// direction briefly through the transient dip you get when rotating the stick past a
    /// sector boundary, which is what makes strafing feel like it stutters.
    private var pendingRelease: [Slot: Date] = [:]

    /// Hotbar slot tracked locally, only meaningful when `hotbarMode == .numbers`.
    private var hotbarSlot = 1

    /// When suspended the driver reads the pad but emits nothing, apart from the toggle
    /// itself. Gives the player a way to alt-tab or type without the stick fighting them.
    private(set) var suspended = false

    public init(config: Config, synth: EventSynth, verbose: Bool, source: URL? = nil) throws {
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

    public func ingest(report: [UInt8]) {
        guard let decoded = ControllerState.decode(report: report, bitOrder: config.buttonBitOrder)
        else { return }
        state = decoded
    }

    /// Called when the pad disappears: drop every held key so nothing sticks.
    public func handleDisconnect() {
        state = ControllerState()
        releaseEverything()
        activeSlots.removeAll()
    }

    // MARK: - Tick

    public func tick() {
        let now = Date()
        let dt = min(now.timeIntervalSince(lastTick), 0.1)  // clamp after a stall
        lastTick = now
        guard state.connected else { return }

        updateLook(dt: dt)
        updateSlots(now: now)
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
            let target = Engine.shape(x: x, y: y, look: stick.look)

            // Exponential smoothing, framed as a time constant so the feel does not change
            // when pollRateHz does. alpha = 1 - e^(-dt/tau) is the frame-rate-independent
            // form; a plain fixed alpha would smooth twice as hard at twice the tick rate.
            let tau = stick.look.smoothingMs / 1000
            let alpha = tau > 0 ? 1 - exp(-dt / tau) : 1
            var smoothed = lookSmoothed[side] ?? (0, 0)
            smoothed.x += (target.0 - smoothed.x) * alpha
            smoothed.y += (target.1 - smoothed.y) * alpha
            // Let it settle to a true zero rather than creeping for ever on a tail that
            // never quite reaches it, which would read as slow camera drift at rest.
            if target.0 == 0, target.1 == 0, abs(smoothed.x) < 1e-4, abs(smoothed.y) < 1e-4 {
                smoothed = (0, 0)
            }
            lookSmoothed[side] = smoothed

            dx += smoothed.x * stick.look.sensitivityX * dt * (stick.look.invertX ? -1 : 1)
            dy += smoothed.y * stick.look.sensitivityY * dt * (stick.look.invertY ? -1 : 1)
        }

        // Pass the real-valued motion through; EventSynth owns the quantisation, since
        // the absolute position and the delta field have different precision limits.
        synth.moveMouse(deltaX: dx, deltaY: dy)
    }

    /// Apply a radial deadzone and a response curve.
    ///
    /// The deadzone is radial rather than per-axis so that a diagonal push is not clipped
    /// into an axis-aligned one, and the magnitude is rescaled across the remaining travel
    /// so the very first movement past the deadzone is slow instead of jumping.
    public static func shape(x: Double, y: Double, look: LookBinding) -> (Double, Double) {
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

    private func updateSlots(now: Date) {
        var nowActive: Set<Slot> = []
        for button in state.buttons { nowActive.insert(.button(button)) }
        for direction in state.dpad { nowActive.insert(.dpad(direction)) }
        for (side, stick) in [(StickSide.left, config.leftStick), (.right, config.rightStick)]
        where stick.role == .move {
            nowActive.formUnion(moveDirections(side: side, binding: stick.move, now: now))
        }

        for slot in nowActive.subtracting(activeSlots) { press(slot) }
        for slot in activeSlots.subtracting(nowActive) { release(slot) }
        activeSlots = nowActive
    }

    /// Convert a stick position into directional slots.
    ///
    /// Engagement is decided on the stick's *radial* distance, and direction only on its
    /// angle. Testing each axis against the threshold separately — as this used to — meant
    /// a diagonal push had to travel 1/cos(45°) ≈ 1.41x as far as a cardinal one before
    /// anything happened, so walking forward engaged noticeably sooner than strafing
    /// diagonally. Deciding on magnitude makes every direction engage at the same distance.
    private func moveDirections(side: StickSide, binding: MoveBinding, now: Date) -> Set<Slot> {
        let (x, y) = axes(for: side)
        let magnitude = (x * x + y * y).squareRoot()

        func slot(_ direction: DPadID) -> Slot { .move(stick: side, direction: direction) }
        let wasEngaged = DPadID.allCases.contains { activeSlots.contains(slot($0)) }

        // Hysteresis on engagement: once moving, the stick may fall a little further back
        // before movement stops, so resting near the threshold cannot machine-gun the key.
        let engageAt = wasEngaged
            ? max(binding.threshold - binding.releaseHysteresis, 0.05)
            : binding.threshold

        var desired: Set<Slot> = []
        if magnitude >= engageAt {
            let nx = x / magnitude
            let ny = y / magnitude
            // A direction counts when its share of the push clears the tolerance. At the
            // default 0.38 that is sin(22.5°), giving eight equal 45° sectors. A direction
            // already held is kept on a slacker bound so the stick cannot flicker between
            // "north" and "north-east" while being rotated.
            func consider(_ component: Double, _ direction: DPadID) {
                let held = activeSlots.contains(slot(direction))
                let bound = held ? binding.directionTolerance * 0.75 : binding.directionTolerance
                if component >= bound { desired.insert(slot(direction)) }
            }
            // Y is negative-up in the report, matching screen coordinates.
            consider(-ny, .up)
            consider(ny, .down)
            consider(-nx, .left)
            consider(nx, .right)
        }

        return applyReleaseDelay(desired, side: side, delayMs: binding.releaseDelayMs, now: now)
    }

    /// Hold a direction for a short grace period after it would otherwise be released.
    ///
    /// Rotating the stick from forward to strafe passes through angles where a key briefly
    /// stops qualifying, and releasing on that single tick produces an audible stutter in
    /// the game. Waiting a few tens of milliseconds before acting on a release smooths the
    /// transition without adding latency to a genuine stop, which stays below threshold.
    private func applyReleaseDelay(_ desired: Set<Slot>, side: StickSide,
                                   delayMs: Double, now: Date) -> Set<Slot> {
        guard delayMs > 0 else { return desired }
        var result = desired
        for slot in desired { pendingRelease[slot] = nil }

        for direction in DPadID.allCases {
            let slot = Slot.move(stick: side, direction: direction)
            guard activeSlots.contains(slot), !desired.contains(slot) else { continue }
            let since = pendingRelease[slot] ?? now
            pendingRelease[slot] = since
            if now.timeIntervalSince(since) < delayMs / 1000 {
                result.insert(slot)
            } else {
                pendingRelease[slot] = nil
            }
        }
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

    public func setSuspended(_ value: Bool) {
        guard value != suspended else { return }
        suspended = value
        if value { releaseEverything() }
        log(value ? "⏸  suspended — output muted" : "▶️  resumed")
    }

    /// Drop every key, mouse button and latch we are responsible for.
    public func releaseEverything() {
        var keys: [CGKeyCode] = []
        for (_, action) in heldOutputs {
            if case .key(let code, _, _, _) = action { keys.append(code) }
        }
        synth.releaseAll(keys: keys)
        heldOutputs.removeAll()
        latched.removeAll()
        repeatDue.removeAll()
        pendingRelease.removeAll()
        // Drop the filter too, so resuming starts from rest rather than replaying motion
        // banked before the pause.
        lookSmoothed.removeAll()
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
