import Foundation

/// Logical inputs on the HiWonder PS2 pad, in the order the adapter reports them.
///
/// The adapter (VID 0x2563 / PID 0x0575) publishes a 27-byte input report:
///
///     byte  0..1   13 button bits, LSB first (bits 13..15 are padding)
///     byte  2      D-pad hat in the low nibble (0=N, 2=E, 4=S, 6=W, 8/15=centre)
///     byte  3..6   X, Y, Z, Rz  — left stick X/Y then right stick X/Y, each 0...255
///     byte  7..26  vendor-defined analog pressure data (unused here)
///
/// The bit index each face button occupies is *not* fixed across PS2 adapter clones, so
/// `ButtonID.defaultBitOrder` is only a starting point — `ps2mc calibrate` rewrites it into
/// the config after watching the user press each button.
public enum ButtonID: String, CaseIterable, Codable {
    case y, b, a, x
    case l1, r1, l2, r2
    case select, start
    case l3, r3
    case analog

    /// Bit index in the 13-bit button field, as shipped by most 2563:0575 adapters.
    public static let defaultBitOrder: [ButtonID] = [
        .y, .b, .a, .x,
        .l1, .r1, .l2, .r2,
        .select, .start, .l3, .r3, .analog,
    ]

    /// PlayStation shape names, accepted wherever a button name is read.
    ///
    /// These pads are sold with either lettering; the HiWonder unit is labelled Y/A/X/B.
    /// The shapes map by *position* — Y and △ are both the top button, and so on — so a
    /// config written against either labelling resolves to the same physical button.
    public static let aliases: [String: ButtonID] = [
        "triangle": .y, "tri": .y,
        "circle": .b, "o": .b,
        "cross": .a,
        "square": .x,
    ]

    /// Look up a button by canonical name or alias.
    ///
    /// Note that `x` is deliberately *not* aliased to Cross: on a letter-labelled pad X is
    /// the left button, which is Square. Silently accepting the PlayStation reading of "x"
    /// would put drop-item on the wrong button for everyone typing the letters they see.
    public static func named(_ name: String) -> ButtonID? {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        return ButtonID(rawValue: key) ?? aliases[key]
    }

    /// Label shown in `calibrate` and `monitor`.
    public var displayName: String {
        switch self {
        case .y:      return "Y (top)"
        case .b:      return "B (right)"
        case .a:      return "A (bottom)"
        case .x:      return "X (left)"
        case .l1:     return "L1 (upper-left bumper)"
        case .r1:     return "R1 (upper-right bumper)"
        case .l2:     return "L2 (lower-left trigger)"
        case .r2:     return "R2 (lower-right trigger)"
        case .select: return "Select"
        case .start:  return "Start"
        case .l3:     return "L3 (left stick click)"
        case .r3:     return "R3 (right stick click)"
        case .analog: return "Analog / Mode"
        }
    }

    /// Accept aliases when decoding, so a config using the shape names still loads.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let resolved = ButtonID.named(raw) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "'\(raw)' is not a button — expected one of "
                    + ButtonID.allCases.map(\.rawValue).joined(separator: ", "))
        }
        self = resolved
    }
}

/// The four D-pad directions, surfaced as discrete buttons even though the wire format
/// encodes them as an 8-way hat.
public enum DPadID: String, CaseIterable, Codable {
    case up, down, left, right
}

/// One decoded input report.
public struct ControllerState {
    public var buttons: Set<ButtonID> = []
    public var dpad: Set<DPadID> = []
    /// Stick axes, normalised to -1...1. Y is negative-up, matching screen coordinates.
    public var leftX: Double = 0
    public var leftY: Double = 0
    public var rightX: Double = 0
    public var rightY: Double = 0
    /// True once at least one report has been decoded.
    public var connected: Bool = false

    public static let reportLength = 27

    public init() {}

    /// Normalise a 0...255 axis byte to -1...1, treating 128 as centre.
    private static func axis(_ raw: UInt8) -> Double {
        // 0...255 maps to -1...1 with an exact zero at the 127/128 boundary. Dividing the
        // negative half by 127.5 and the positive half by 127.5 keeps both ends reaching
        // full scale without an asymmetric dead spot at centre.
        (Double(raw) - 127.5) / 127.5
    }

    /// Decode a raw report using the given bit order. Returns nil for short reports.
    public static func decode(report: [UInt8], bitOrder: [ButtonID]) -> ControllerState? {
        guard report.count >= 7 else { return nil }
        var state = ControllerState()
        state.connected = true

        let bits = UInt16(report[0]) | (UInt16(report[1]) << 8)
        for (index, button) in bitOrder.enumerated() where index < 13 {
            if bits & (1 << UInt16(index)) != 0 {
                state.buttons.insert(button)
            }
        }

        switch report[2] & 0x0F {
        case 0: state.dpad = [.up]
        case 1: state.dpad = [.up, .right]
        case 2: state.dpad = [.right]
        case 3: state.dpad = [.down, .right]
        case 4: state.dpad = [.down]
        case 5: state.dpad = [.down, .left]
        case 6: state.dpad = [.left]
        case 7: state.dpad = [.up, .left]
        default: state.dpad = []
        }

        state.leftX = axis(report[3])
        state.leftY = axis(report[4])
        state.rightX = axis(report[5])
        state.rightY = axis(report[6])
        return state
    }
}
