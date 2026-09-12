import CoreGraphics
import Foundation

/// Maps human-readable key names (as used in the JSON config) to virtual keycodes.
///
/// These are ANSI/US-layout virtual keycodes from `<Carbon/HIToolbox/Events.h>`. Minecraft
/// (GLFW) keys off physical key position rather than the typed character, so a fixed ANSI
/// table is what we want here — it keeps `key:w` on the same physical key regardless of the
/// user's active input source.
enum Keycodes {
    static let table: [String: CGKeyCode] = [
        // Letters
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "o": 0x1F,
        "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
        "n": 0x2D, "m": 0x2E,

        // Number row
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17, "6": 0x16,
        "7": 0x1A, "8": 0x1C, "9": 0x19, "0": 0x1D,

        // Punctuation
        "minus": 0x1B, "equal": 0x18, "leftbracket": 0x21, "rightbracket": 0x1E,
        "backslash": 0x2A, "semicolon": 0x29, "quote": 0x27, "comma": 0x2B,
        "period": 0x2F, "slash": 0x2C, "grave": 0x32,

        // Control / whitespace
        "space": 0x31, "return": 0x24, "enter": 0x24, "tab": 0x30,
        "delete": 0x33, "backspace": 0x33, "escape": 0x35, "esc": 0x35,
        "forwarddelete": 0x75,

        // Modifiers (usable as standalone keys as well as flags)
        "shift": 0x38, "leftshift": 0x38, "rightshift": 0x3C,
        "control": 0x3B, "ctrl": 0x3B, "leftcontrol": 0x3B, "rightcontrol": 0x3E,
        "option": 0x3A, "alt": 0x3A, "leftoption": 0x3A, "rightoption": 0x3D,
        "command": 0x37, "cmd": 0x37, "leftcommand": 0x37, "rightcommand": 0x36,
        "capslock": 0x39, "function": 0x3F, "fn": 0x3F,

        // Arrows
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,

        // Navigation
        "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,

        // Function keys
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
        "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
        "f13": 0x69, "f14": 0x6B, "f15": 0x71, "f16": 0x6A, "f17": 0x40,
        "f18": 0x4F, "f19": 0x50, "f20": 0x5A,

        // Keypad
        "keypad0": 0x52, "keypad1": 0x53, "keypad2": 0x54, "keypad3": 0x55,
        "keypad4": 0x56, "keypad5": 0x57, "keypad6": 0x58, "keypad7": 0x59,
        "keypad8": 0x5B, "keypad9": 0x5C, "keypaddecimal": 0x41,
        "keypadmultiply": 0x43, "keypadplus": 0x45, "keypadminus": 0x4E,
        "keypaddivide": 0x4B, "keypadenter": 0x4C, "keypadequals": 0x51,
        "keypadclear": 0x47,
    ]

    /// Modifier names that can prefix a key in a combo (`combo:shift+w`).
    static let modifierFlags: [String: CGEventFlags] = [
        "shift": .maskShift, "leftshift": .maskShift, "rightshift": .maskShift,
        "control": .maskControl, "ctrl": .maskControl,
        "leftcontrol": .maskControl, "rightcontrol": .maskControl,
        "option": .maskAlternate, "alt": .maskAlternate,
        "leftoption": .maskAlternate, "rightoption": .maskAlternate,
        "command": .maskCommand, "cmd": .maskCommand,
        "leftcommand": .maskCommand, "rightcommand": .maskCommand,
        "fn": .maskSecondaryFn, "function": .maskSecondaryFn,
    ]

    static func code(for name: String) -> CGKeyCode? {
        table[name.lowercased()]
    }

    /// Every recognised key name, sorted — used by `ps2mc keys`.
    static var allNames: [String] { table.keys.sorted() }
}
