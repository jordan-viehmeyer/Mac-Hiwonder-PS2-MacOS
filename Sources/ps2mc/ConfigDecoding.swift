import Foundation

// The config file is meant to be edited by hand, so a missing key must mean "use the
// default", not "fail to start". The synthesised `Codable` conformances throw on absent
// keys, so each type spells out a lenient decoder instead.

extension CodingUserInfoKey {
    /// Set by `ps2mc selftest`, which decodes deliberately broken configs and would
    /// otherwise print repair warnings that read like real failures.
    static let suppressWarnings = CodingUserInfoKey(rawValue: "ps2mc.suppressWarnings")!
}

extension LookBinding {
    enum CodingKeys: String, CodingKey {
        case sensitivityX, sensitivityY, deadzone, exponent, invertY, invertX
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LookBinding.minecraftDefault
        sensitivityX = try c.decodeIfPresent(Double.self, forKey: .sensitivityX) ?? d.sensitivityX
        sensitivityY = try c.decodeIfPresent(Double.self, forKey: .sensitivityY) ?? d.sensitivityY
        deadzone = try c.decodeIfPresent(Double.self, forKey: .deadzone) ?? d.deadzone
        exponent = try c.decodeIfPresent(Double.self, forKey: .exponent) ?? d.exponent
        invertY = try c.decodeIfPresent(Bool.self, forKey: .invertY) ?? d.invertY
        invertX = try c.decodeIfPresent(Bool.self, forKey: .invertX) ?? d.invertX
    }
}

extension MoveBinding {
    enum CodingKeys: String, CodingKey {
        case up, down, left, right, threshold, releaseHysteresis
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MoveBinding.minecraftDefault
        up = try c.decodeIfPresent(String.self, forKey: .up) ?? d.up
        down = try c.decodeIfPresent(String.self, forKey: .down) ?? d.down
        left = try c.decodeIfPresent(String.self, forKey: .left) ?? d.left
        right = try c.decodeIfPresent(String.self, forKey: .right) ?? d.right
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? d.threshold
        releaseHysteresis = try c.decodeIfPresent(Double.self, forKey: .releaseHysteresis)
            ?? d.releaseHysteresis
    }
}

extension StickConfig {
    enum CodingKeys: String, CodingKey {
        case role, look, move
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decodeIfPresent(StickRole.self, forKey: .role) ?? .none
        look = try c.decodeIfPresent(LookBinding.self, forKey: .look) ?? .minecraftDefault
        move = try c.decodeIfPresent(MoveBinding.self, forKey: .move) ?? .minecraftDefault
    }
}

extension Config {
    enum CodingKeys: String, CodingKey {
        case version, vendorID, productID, matchAnyGamepad, buttonBitOrder
        case pollRateHz, hotbarMode, repeatIntervalMs, repeatDelayMs
        case leftStick, rightStick, buttons, dpad
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? d.version
        vendorID = try c.decodeIfPresent(Int.self, forKey: .vendorID) ?? d.vendorID
        productID = try c.decodeIfPresent(Int.self, forKey: .productID) ?? d.productID
        matchAnyGamepad = try c.decodeIfPresent(Bool.self, forKey: .matchAnyGamepad)
            ?? d.matchAnyGamepad
        buttonBitOrder = try c.decodeIfPresent([ButtonID].self, forKey: .buttonBitOrder)
            ?? d.buttonBitOrder
        pollRateHz = try c.decodeIfPresent(Double.self, forKey: .pollRateHz) ?? d.pollRateHz
        hotbarMode = try c.decodeIfPresent(HotbarMode.self, forKey: .hotbarMode) ?? d.hotbarMode
        repeatIntervalMs = try c.decodeIfPresent(Double.self, forKey: .repeatIntervalMs)
            ?? d.repeatIntervalMs
        repeatDelayMs = try c.decodeIfPresent(Double.self, forKey: .repeatDelayMs)
            ?? d.repeatDelayMs
        leftStick = try c.decodeIfPresent(StickConfig.self, forKey: .leftStick) ?? d.leftStick
        rightStick = try c.decodeIfPresent(StickConfig.self, forKey: .rightStick) ?? d.rightStick
        buttons = try c.decodeIfPresent([String: String].self, forKey: .buttons) ?? d.buttons
        dpad = try c.decodeIfPresent([String: String].self, forKey: .dpad) ?? d.dpad

        // Guard rails on the numeric knobs: a zero poll rate or a deadzone of 1.0 would
        // leave the driver silently doing nothing, which is far harder to diagnose than a
        // value that was quietly clamped back into a usable range.
        pollRateHz = min(max(pollRateHz, 30), 500)
        repeatIntervalMs = max(repeatIntervalMs, 16)
        repeatDelayMs = max(repeatDelayMs, 0)

        if buttonBitOrder.count != 13 || Set(buttonBitOrder).count != 13 {
            if decoder.userInfo[.suppressWarnings] as? Bool != true {
                FileHandle.standardError.write(
                    "ps2mc: buttonBitOrder must list all 13 buttons exactly once — using defaults\n"
                        .data(using: .utf8)!)
            }
            buttonBitOrder = ButtonID.defaultBitOrder
        }
    }
}
