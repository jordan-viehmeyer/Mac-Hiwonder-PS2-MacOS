import CoreGraphics
import Foundation

/// How an action behaves while its source button is held.
public enum ActionMode: String, Codable {
    /// Press on button-down, release on button-up. The default, and what movement keys want.
    case hold
    /// Press-and-release once per button-down, ignoring how long it is held.
    case tap
    /// Each button-down flips a latch; the key stays down until the next press.
    case toggle
    /// Press once immediately, then auto-repeat while held.
    case repeatWhileHeld = "repeat"
}

public enum MouseButtonID: String, Codable {
    case left, right, middle

    public var cgButton: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }
}

public enum ScrollDirection: String, Codable {
    case up, down, left, right
}

/// A single mapped behaviour. Written in config as a compact string so the file stays
/// hand-editable: `"<kind>:<value>[@<mode>]"`.
///
///     key:w                 hold W while the button is held
///     key:space@tap         one W press per button press
///     key:shift@toggle      latch sneak on/off
///     key:q@repeat          drop-stack auto-repeat
///     combo:shift+w         hold Shift and W together
///     mouse:left            hold left click (Minecraft: attack / destroy)
///     scroll:up             one wheel notch up
///     hotbar:next           advance one hotbar slot (respects config.hotbarMode)
///     special:toggleEngine  suspend/resume all output
///     none                  explicitly unmapped
public enum Action: Equatable {
    case key(CGKeyCode, name: String, flags: CGEventFlags, mode: ActionMode)
    case mouse(MouseButtonID, mode: ActionMode)
    case scroll(ScrollDirection, amount: Int32)
    case hotbarNext
    case hotbarPrev
    case hotbarSlot(Int)
    case toggleEngine
    case none

    /// Actions whose pressed/released state must be tracked to be released later.
    public var isStateful: Bool {
        switch self {
        case .key(_, _, _, let mode), .mouse(_, let mode):
            return mode == .hold || mode == .toggle || mode == .repeatWhileHeld
        default:
            return false
        }
    }
}

public enum ActionParseError: LocalizedError {
    case unknownKind(String, spec: String)
    case unknownKey(String, spec: String)
    case unknownMode(String, spec: String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .unknownKind(let kind, let spec):
            return "unknown action kind '\(kind)' in \"\(spec)\" — expected key, combo, mouse, scroll, hotbar, special, or none"
        case .unknownKey(let key, let spec):
            return "unknown key name '\(key)' in \"\(spec)\" — run `ps2mc keys` for the full list"
        case .unknownMode(let mode, let spec):
            return "unknown mode '\(mode)' in \"\(spec)\" — expected hold, tap, toggle, or repeat"
        case .malformed(let spec):
            return "could not parse action \"\(spec)\""
        }
    }
}

public extension Action {
    public static func parse(_ spec: String) throws -> Action {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.lowercased() == "none" { return .none }

        // Split the optional trailing "@mode".
        var body = trimmed
        var mode = ActionMode.hold
        if let at = trimmed.lastIndex(of: "@") {
            body = String(trimmed[trimmed.startIndex..<at])
            let modeText = String(trimmed[trimmed.index(after: at)...]).lowercased()
            guard let parsed = ActionMode(rawValue: modeText) else {
                throw ActionParseError.unknownMode(modeText, spec: spec)
            }
            mode = parsed
        }

        guard let colon = body.firstIndex(of: ":") else {
            throw ActionParseError.malformed(spec)
        }
        let kind = String(body[body.startIndex..<colon]).lowercased()
        let value = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

        switch kind {
        case "key":
            guard let code = Keycodes.code(for: value) else {
                throw ActionParseError.unknownKey(value, spec: spec)
            }
            return .key(code, name: value.lowercased(), flags: [], mode: mode)

        case "combo":
            // "shift+w" — every component but the last is a modifier flag.
            let parts = value.split(separator: "+").map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }
            guard let last = parts.last, !last.isEmpty else {
                throw ActionParseError.malformed(spec)
            }
            var flags: CGEventFlags = []
            for modifier in parts.dropLast() {
                guard let flag = Keycodes.modifierFlags[modifier] else {
                    throw ActionParseError.unknownKey(modifier, spec: spec)
                }
                flags.insert(flag)
            }
            guard let code = Keycodes.code(for: last) else {
                throw ActionParseError.unknownKey(last, spec: spec)
            }
            return .key(code, name: value.lowercased(), flags: flags, mode: mode)

        case "mouse":
            guard let button = MouseButtonID(rawValue: value.lowercased()) else {
                throw ActionParseError.unknownKey(value, spec: spec)
            }
            return .mouse(button, mode: mode)

        case "scroll":
            // "up" or "up*3" for a coarser notch.
            let pieces = value.lowercased().split(separator: "*")
            guard let name = pieces.first,
                  let direction = ScrollDirection(rawValue: String(name)) else {
                throw ActionParseError.unknownKey(value, spec: spec)
            }
            let amount = pieces.count > 1 ? Int32(pieces[1]) ?? 1 : 1
            return .scroll(direction, amount: max(1, amount))

        case "hotbar":
            let lowered = value.lowercased()
            if lowered == "next" { return .hotbarNext }
            if lowered == "prev" || lowered == "previous" { return .hotbarPrev }
            if let slot = Int(lowered), (1...9).contains(slot) { return .hotbarSlot(slot) }
            throw ActionParseError.unknownKey(value, spec: spec)

        case "special":
            switch value.lowercased() {
            case "toggleengine", "toggle": return .toggleEngine
            default: throw ActionParseError.unknownKey(value, spec: spec)
            }

        default:
            throw ActionParseError.unknownKind(kind, spec: spec)
        }
    }
}
