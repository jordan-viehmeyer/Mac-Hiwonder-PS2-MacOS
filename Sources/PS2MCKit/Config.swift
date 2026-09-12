import Foundation

/// What a stick drives.
public enum StickRole: String, Codable {
    /// Drives the mouse cursor — Minecraft camera look.
    case look
    /// Drives four directional keys (WASD by default).
    case move
    /// Ignored.
    case none
}

/// Which keys a `move` stick presses, and how far it must travel first.
public struct MoveBinding: Codable {
    public var up: String
    public var down: String
    public var left: String
    public var right: String
    /// Radial distance (0...1) the stick must travel before movement engages.
    public var threshold: Double
    /// Extra travel required to *release*, so a stick resting on the edge cannot chatter.
    public var releaseHysteresis: Double
    /// How much of the push must point along an axis for that direction to count, once
    /// engaged. 0.38 is sin(22.5°), which gives eight equal 45° sectors. Lower widens the
    /// diagonals at the expense of the cardinals; higher does the reverse.
    public var directionTolerance: Double
    /// Grace period before a direction is actually released, in milliseconds. Smooths the
    /// transient dips you get rotating the stick between sectors. 0 disables it.
    public var releaseDelayMs: Double

    public init(up: String, down: String, left: String, right: String,
                threshold: Double, releaseHysteresis: Double,
                directionTolerance: Double, releaseDelayMs: Double) {
        self.up = up; self.down = down; self.left = left; self.right = right
        self.threshold = threshold; self.releaseHysteresis = releaseHysteresis
        self.directionTolerance = directionTolerance; self.releaseDelayMs = releaseDelayMs
    }

    public static let minecraftDefault = MoveBinding(
        up: "key:w",
        down: "key:s",
        left: "key:a",
        right: "key:d",
        threshold: 0.30,
        releaseHysteresis: 0.08,
        directionTolerance: 0.38,
        releaseDelayMs: 40
    )
}

/// Mouse-look tuning for a `look` stick.
public struct LookBinding: Codable {
    /// Pixels of mouse travel per second at full stick deflection.
    public var sensitivityX: Double
    public var sensitivityY: Double
    /// Radial deadzone as a fraction of full deflection.
    public var deadzone: Double
    /// Response curve exponent. 1.0 is linear; higher gives finer control near centre.
    public var exponent: Double
    /// Flip vertical look (classic inverted-Y flight-sim style).
    public var invertY: Bool
    public var invertX: Bool
    /// Smoothing time constant in milliseconds. Larger is smoother but less immediate;
    /// 0 disables the filter entirely. 25–50 ms takes the edge off without feeling laggy.
    public var smoothingMs: Double

    // Why these numbers: the window server truncates mouse deltas to whole pixels, so a
    // pan of N px/s arrives as N discrete 1 px steps per second no matter how smooth the
    // driver's own maths is. Fine aim therefore gets smoother by moving *more* pixels,
    // not fewer. The old 1100 px/s also meant a 360° turn took over two seconds, which is
    // both unplayable and the very condition that makes the stepping visible. At 2800 a
    // full turn takes about 0.85 s and a slow pan runs ~190 steps/s instead of ~43.
    public init(sensitivityX: Double, sensitivityY: Double, deadzone: Double,
                exponent: Double, invertY: Bool, invertX: Bool, smoothingMs: Double) {
        self.sensitivityX = sensitivityX; self.sensitivityY = sensitivityY
        self.deadzone = deadzone; self.exponent = exponent
        self.invertY = invertY; self.invertX = invertX; self.smoothingMs = smoothingMs
    }

    public static let minecraftDefault = LookBinding(
        sensitivityX: 2800,
        sensitivityY: 2000,
        deadzone: 0.10,
        exponent: 1.5,
        invertY: false,
        invertX: false,
        smoothingMs: 28
    )
}

public struct StickConfig: Codable {
    public var role: StickRole
    public var look: LookBinding
    public var move: MoveBinding

    public init(role: StickRole, look: LookBinding, move: MoveBinding) {
        self.role = role; self.look = look; self.move = move
    }
}

/// How `hotbar:next` / `hotbar:prev` reach Minecraft.
public enum HotbarMode: String, Codable {
    /// Post a mouse-wheel notch. Matches Minecraft's own hotbar scrolling and can never
    /// drift out of sync with the game, since the game owns the slot index.
    case scroll
    /// Track the slot locally and press 1...9. Deterministic, but desyncs if the player
    /// also scrolls or clicks a slot directly.
    case numbers
}

public struct Config: Codable {
    public init() {}

    /// Bumped when the schema changes so `ps2mc` can migrate or warn.
    public var version: Int = 1

    /// USB identifiers to match. Defaults to the HiWonder PS2 receiver.
    public var vendorID: Int = 0x2563
    public var productID: Int = 0x0575
    /// Fall back to any HID gamepad/joystick if the exact VID/PID is absent.
    public var matchAnyGamepad: Bool = true

    /// Button bit order in the 13-bit field. Rewritten by `ps2mc calibrate`.
    public var buttonBitOrder: [ButtonID] = ButtonID.defaultBitOrder

    /// How often stick state is converted into mouse motion, in hertz.
    ///
    /// Deliberately above the receiver's own 125 Hz report rate: the smoothing filter
    /// interpolates between reports, so the extra ticks space the emitted motion more
    /// evenly in time rather than inventing detail.
    public var pollRateHz: Double = 250

    public var hotbarMode: HotbarMode = .scroll

    /// Milliseconds between repeats for `@repeat` actions.
    public var repeatIntervalMs: Double = 120
    /// Delay before `@repeat` starts repeating.
    public var repeatDelayMs: Double = 350

    /// Left stick moves, right stick looks — the console-Minecraft convention.
    public var leftStick: StickConfig = StickConfig(
        role: .move,
        look: .minecraftDefault,
        move: .minecraftDefault
    )
    public var rightStick: StickConfig = StickConfig(
        role: .look,
        look: .minecraftDefault,
        move: .minecraftDefault
    )

    /// Face/shoulder/system buttons.
    public var buttons: [String: String] = Config.defaultButtons
    /// D-pad directions.
    public var dpad: [String: String] = Config.defaultDPad

    public static let defaultButtons: [String: String] = [
        // --- The mappings called out in the brief -------------------------------
        // Lower triggers are Minecraft's two world-interaction verbs.
        "l2": "mouse:left",          // destroy / attack
        "r2": "mouse:right",         // place / use
        // Upper bumpers step through the hotbar.
        "l1": "hotbar:prev",
        "r1": "hotbar:next",

        // --- Everything else, tuned for Minecraft --------------------------------
        "a": "key:space",            // jump      (bottom button)
        "b": "key:shift@toggle",     // sneak latch — no thumb fatigue on long descents
        "y": "key:e",                // inventory  (top button)
        "x": "key:q@repeat",         // drop; held to empty a stack

        "l3": "key:f",               // swap item to off-hand
        "r3": "key:control@toggle",  // sprint latch

        "select": "key:tab",         // player list
        "start": "key:escape",       // pause / release mouse grab
        "analog": "special:toggleEngine",
    ]

    public static let defaultDPad: [String: String] = [
        "up": "key:t",               // chat
        "down": "key:f5",            // cycle camera perspective
        "left": "hotbar:1",          // jump to first hotbar slot
        "right": "hotbar:9",         // jump to last hotbar slot
    ]

    // MARK: - Persistence

    public static var directory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/ps2mc", isDirectory: true)
    }

    public static var path: URL {
        directory.appendingPathComponent("config.json")
    }

    public static func load(from url: URL = Config.path) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let fresh = Config()
            try fresh.save(to: url)
            FileHandle.standardError.write(
                "ps2mc: wrote default config to \(url.path)\n".data(using: .utf8)!)
            return fresh
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(Config.self, from: data)
    }

    public func save(to url: URL = Config.path) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Resolve every string binding into an `Action`, reporting *all* bad entries at once
    /// rather than dying on the first one — a typo mid-file shouldn't hide the rest.
    ///
    /// `source` is only used to name the file in the error, so a `--config` run points at
    /// the file the user actually edited.
    public func resolveBindings(source: URL? = nil)
        throws -> (buttons: [ButtonID: Action], dpad: [DPadID: Action]) {
        var problems: [String] = []
        var resolvedButtons: [ButtonID: Action] = [:]
        var resolvedDPad: [DPadID: Action] = [:]

        for (name, spec) in buttons {
            guard let id = ButtonID.named(name) else {
                problems.append("buttons.\(name): not a button — valid names: "
                    + ButtonID.allCases.map(\.rawValue).joined(separator: ", "))
                continue
            }
            do { resolvedButtons[id] = try Action.parse(spec) }
            catch { problems.append("buttons.\(name): \(error.localizedDescription)") }
        }

        for (name, spec) in dpad {
            guard let id = DPadID(rawValue: name.lowercased()) else {
                problems.append("dpad.\(name): not a direction — valid names: up, down, left, right")
                continue
            }
            do { resolvedDPad[id] = try Action.parse(spec) }
            catch { problems.append("dpad.\(name): \(error.localizedDescription)") }
        }

        for (label, stick) in [("leftStick", leftStick), ("rightStick", rightStick)]
        where stick.role == .move {
            for (axis, spec) in [("up", stick.move.up), ("down", stick.move.down),
                                 ("left", stick.move.left), ("right", stick.move.right)] {
                do { _ = try Action.parse(spec) }
                catch { problems.append("\(label).move.\(axis): \(error.localizedDescription)") }
            }
        }

        guard problems.isEmpty else {
            throw ConfigError.invalidBindings(problems, source: source ?? Config.path)
        }
        return (resolvedButtons, resolvedDPad)
    }
}

public enum ConfigError: LocalizedError {
    case invalidBindings([String], source: URL)

    public var errorDescription: String? {
        switch self {
        case .invalidBindings(let problems, let source):
            return "invalid bindings in \(source.path):\n  - "
                + problems.joined(separator: "\n  - ")
        }
    }
}
