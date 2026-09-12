import Foundation

/// Live view of decoded controller state, redrawn in place on one line block.
///
/// This is the tool for answering "is the pad reaching the Mac at all?" and for checking a
/// calibration, so it prints what the driver itself sees rather than raw bytes by default.
enum Monitor {
    private static var lineCount = 0
    private static var lastPaint = Date.distantPast
    /// Cursor-movement escapes only make sense on a terminal; redirected to a file or a
    /// pipe they turn the log into noise, so fall back to plain periodic lines there.
    private static let isTerminal = isatty(STDOUT_FILENO) == 1

    static func render(report: [UInt8], config: Config, raw: Bool) {
        // The receiver streams at 125 Hz; repainting that fast just makes the terminal
        // flicker and hides the values being read.
        let now = Date()
        guard now.timeIntervalSince(lastPaint) > (isTerminal ? 0.05 : 1.0) else { return }
        lastPaint = now

        guard let state = ControllerState.decode(report: report, bitOrder: config.buttonBitOrder)
        else { return }

        var lines: [String] = []
        if raw {
            lines.append("raw   " + report.map { String(format: "%02x", $0) }.joined(separator: " "))
        }
        lines.append(String(format: "left  X %+.2f  Y %+.2f   %@",
                            state.leftX, state.leftY, bar(state.leftX, state.leftY)))
        lines.append(String(format: "right X %+.2f  Y %+.2f   %@",
                            state.rightX, state.rightY, bar(state.rightX, state.rightY)))

        let pressed = ButtonID.allCases.filter { state.buttons.contains($0) }
            .map(\.rawValue).joined(separator: " ")
        lines.append("buttons  " + (pressed.isEmpty ? "—" : pressed))

        let dpad = DPadID.allCases.filter { state.dpad.contains($0) }
            .map(\.rawValue).joined(separator: " ")
        lines.append("dpad     " + (dpad.isEmpty ? "—" : dpad))

        guard isTerminal else {
            print(lines.joined(separator: "   |   "))
            fflush(stdout)
            return
        }
        // Redraw over the previous block so the display stays put.
        if lineCount > 0 {
            print("\u{1B}[\(lineCount)A", terminator: "")
        }
        for line in lines {
            print("\u{1B}[2K" + line)
        }
        lineCount = lines.count
        fflush(stdout)
    }

    /// A small ASCII gauge, so stick drift and a dead axis are obvious at a glance.
    private static func bar(_ x: Double, _ y: Double) -> String {
        let magnitude = min((x * x + y * y).squareRoot(), 1)
        let filled = Int((magnitude * 12).rounded())
        return "[" + String(repeating: "█", count: filled)
            + String(repeating: "·", count: 12 - filled) + "]"
    }
}
