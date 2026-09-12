import Foundation

/// What a stick drives.
enum StickRole: String, Codable {
    /// Drives the mouse cursor — Minecraft camera look.
    case look
    /// Drives four directional keys (WASD by default).
    case move
    /// Ignored.
    case none
}

/// Which keys a `move` stick presses, and how far it must travel first.
struct MoveBinding: Codable {
    var up: String
    var down: String
    var left: String
    var right: String
    /// Fraction of full deflection (0...1) before a direction counts as pressed.
    var threshold: Double
    /// Extra travel required to *release* a direction, to stop chattering at the edge.
    var releaseHysteresis: Double

    static let minecraftDefault = MoveBinding(
        up: "key:w",
        down: "key:s",
        left: "key:a",
        right: "key:d",
        threshold: 0.45,
        releaseHysteresis: 0.10
    )
}

/// Mouse-look tuning for a `look` stick.
struct LookBinding: Codable {
    /// Pixels of mouse travel per second at full stick deflection.
    var sensitivityX: Double
    var sensitivityY: Double
    /// Radial deadzone as a fraction of full deflection.
    var deadzone: Double
    /// Response curve exponent. 1.0 is linear; higher gives finer control near centre.
    var exponent: Double
    /// Flip vertical look (classic inverted-Y flight-sim style).
    var invertY: Bool
    var invertX: Bool

    static let minecraftDefault = LookBinding(
        sensitivityX: 1100,
        sensitivityY: 800,
        deadzone: 0.14,
        exponent: 1.9,
        invertY: false,
        invertX: false
    )
}

struct StickConfig: Codable {
    var role: StickRole
    var look: LookBinding
    var move: MoveBinding
}

/// How `hotbar:next` / `hotbar:prev` reach Minecraft.
enum HotbarMode: String, Codable {
    /// Post a mouse-wheel notch. Matches Minecraft's own hotbar scrolling and can never
    /// drift out of sync with the game, since the game owns the slot index.
    case scroll
    /// Track the slot locally and press 1...9. Deterministic, but desyncs if the player
    /// also scrolls or clicks a slot directly.
    case numbers
}

struct Config: Codable {
    /// Bumped when the schema changes so `ps2mc` can migrate or warn.
    var version: Int = 1

    /// USB identifiers to match. Defaults to the HiWonder PS2 receiver.
    var vendorID: Int = 0x2563
    var productID: Int = 0x0575
    /// Fall back to any HID gamepad/joystick if the exact VID/PID is absent.
    var matchAnyGamepad: Bool = true

    /// Button bit order in the 13-bit field. Rewritten by `ps2mc calibrate`.
    var buttonBitOrder: [ButtonID] = ButtonID.defaultBitOrder

    /// How often stick state is converted into mouse motion, in hertz.
    var pollRateHz: Double = 125

    var hotbarMode: HotbarMode = .scroll

    /// Milliseconds between repeats for `@repeat` actions.
    var repeatIntervalMs: Double = 120
    /// Delay before `@repeat` starts repeating.
    var repeatDelayMs: Double = 350

    var leftStick: StickConfig = StickConfig(
        role: .look,
        look: .minecraftDefault,
        move: .minecraftDefault
    )
    var rightStick: StickConfig = StickConfig(
        role: .move,
        look: .minecraftDefault,
        move: .minecraftDefault
    )

    /// Face/shoulder/system buttons.
    var buttons: [String: String] = Config.defaultButtons
    /// D-pad directions.
    var dpad: [String: String] = Config.defaultDPad

    static let defaultButtons: [String: String] = [
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

    static let defaultDPad: [String: String] = [
        "up": "key:t",               // chat
        "down": "key:f5",            // cycle camera perspective
        "left": "hotbar:1",          // jump to first hotbar slot
        "right": "hotbar:9",         // jump to last hotbar slot
    ]

    // MARK: - Persistence

    static var directory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/ps2mc", isDirectory: true)
    }

    static var path: URL {
        directory.appendingPathComponent("config.json")
    }

    static func load(from url: URL = Config.path) throws -> Config {
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

    func save(to url: URL = Config.path) throws {
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
    func resolveBindings(source: URL? = nil)
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

enum ConfigError: LocalizedError {
    case invalidBindings([String], source: URL)

    var errorDescription: String? {
        switch self {
        case .invalidBindings(let problems, let source):
            return "invalid bindings in \(source.path):\n  - "
                + problems.joined(separator: "\n  - ")
        }
    }
}
