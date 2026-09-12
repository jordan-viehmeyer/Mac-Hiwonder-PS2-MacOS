import Foundation

/// Walks the user through pressing each button and records which bit it sets.
///
/// PS2-to-USB adapter clones disagree about the order of the 13 button bits — in particular
/// whether the shoulder block runs L1,R1,L2,R2 or L2,R2,L1,R1 — and getting it wrong silently
/// swaps "destroy block" with "change hotbar slot". Rather than guess from the VID/PID,
/// this observes the actual hardware once and writes the answer into the config.
final class Calibrator {
    private var config: Config
    private let configPath: URL

    private var queue: [ButtonID] = []
    private var current: ButtonID?
    /// bit index -> button, built up as the user presses.
    private var learned: [Int: ButtonID] = [:]
    /// Wait for release before advancing, so one long press cannot fill two entries.
    private var awaitingRelease = false
    /// Set when the press was rejected, so the release re-prompts instead of advancing.
    private var retryCurrent = false
    private var started = false
    private var stdinSource: DispatchSourceRead?

    init(config: Config, configPath: URL) {
        self.config = config
        self.configPath = configPath
    }

    func begin() {
        guard !started else { return }
        started = true
        queue = ButtonID.allCases
        print("""
            Calibration — press each button as it is named.

            It advances on its own when you release the button.
            If your pad has no such button, press Return here to skip it.
            Ctrl-C aborts and leaves the config untouched.

            """)
        watchStandardInput()
        advance()
    }

    private func advance() {
        guard let next = queue.first else { return finish() }
        queue.removeFirst()
        current = next
        print("  → press \(next.displayName)")
        fflush(stdout)
    }

    /// Return on stdin skips the button currently being asked for.
    private func watchStandardInput() {
        let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 256)
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            guard count > 0, let self, self.current != nil else { return }
            print("     – skipped")
            self.awaitingRelease = false
            self.retryCurrent = false
            self.advance()
        }
        source.resume()
        stdinSource = source
    }

    func ingest(report: [UInt8]) {
        guard started, report.count >= 2, let target = current else { return }
        let bits = UInt16(report[0]) | (UInt16(report[1]) << 8)

        if awaitingRelease {
            if bits == 0 {
                awaitingRelease = false
                if retryCurrent {
                    // The press was rejected, so ask for the same button again rather
                    // than moving on and leaving a hole in the map.
                    retryCurrent = false
                    print("  → press \(target.displayName)")
                    fflush(stdout)
                } else {
                    advance()
                }
            }
            return
        }

        // Only accept an unambiguous single-button press.
        guard bits != 0, bits.nonzeroBitCount == 1 else { return }
        let index = bits.trailingZeroBitCount
        guard index < 13 else { return }

        if let existing = learned[index], existing != target {
            print("     ↺ bit \(index) is already \(existing.rawValue) — press a different button")
            awaitingRelease = true
            retryCurrent = true
            return
        }

        learned[index] = target
        print("     ✓ \(target.rawValue) = bit \(index)")
        fflush(stdout)
        awaitingRelease = true
    }

    private func finish() {
        // Any button that was never seen keeps its default position, as long as that
        // position was not claimed by a button we *did* observe.
        var order = [ButtonID?](repeating: nil, count: 13)
        for (index, button) in learned { order[index] = button }
        let missing = ButtonID.allCases.filter { !learned.values.contains($0) }
        var free = (0..<13).filter { order[$0] == nil }
        for button in missing {
            guard let slot = free.first else { break }
            free.removeFirst()
            order[slot] = button
        }

        let resolved = order.compactMap { $0 }
        stdinSource?.cancel()
        guard resolved.count == 13 else {
            print("\nCalibration incomplete — config left unchanged.")
            exit(1)
        }

        config.buttonBitOrder = resolved
        do {
            try config.save(to: configPath)
            print("""

                Saved button order to \(configPath.path)

                  \(resolved.enumerated().map { "\($0.offset):\($0.element.rawValue)" }
                      .joined(separator: "  "))

                Check it with `ps2mc monitor`, then play with `ps2mc run`.
                """)
        } catch {
            print("\nCould not save config — \(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }
}
