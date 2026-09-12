import Foundation

/// Learns which report bit each button occupies by watching the user press them.
///
/// PS2-to-USB adapter clones disagree about the order of the 13 button bits, and getting it
/// wrong silently swaps unrelated actions. This is the shared state machine behind both
/// `ps2mc calibrate` and the app's calibration sheet, so the two cannot drift apart.
public final class ButtonOrderLearner {
    public enum Event: Equatable {
        /// Press this button next.
        case prompt(ButtonID)
        /// That press was recorded.
        case learned(ButtonID, bit: Int)
        /// The bit is already taken; press a different button.
        case rejected(ButtonID, conflictsWith: ButtonID)
        /// Every button has been handled; here is the resulting order.
        case finished([ButtonID])
    }

    private(set) var learned: [Int: ButtonID] = [:]
    private(set) var current: ButtonID?

    private var queue: [ButtonID] = []
    private var awaitingRelease = false
    private var retryCurrent = false
    private var emit: (Event) -> Void

    public init(onEvent: @escaping (Event) -> Void) {
        self.emit = onEvent
    }

    public func begin() {
        queue = ButtonID.allCases
        learned.removeAll()
        awaitingRelease = false
        retryCurrent = false
        advance()
    }

    /// Skip the button being asked for — for a pad that does not have it.
    public func skipCurrent() {
        guard current != nil else { return }
        awaitingRelease = false
        retryCurrent = false
        advance()
    }

    public func ingest(report: [UInt8]) {
        guard report.count >= 2, let target = current else { return }
        let bits = UInt16(report[0]) | (UInt16(report[1]) << 8)

        if awaitingRelease {
            guard bits == 0 else { return }
            awaitingRelease = false
            if retryCurrent {
                // The press was rejected, so ask for the same button again rather than
                // moving on and leaving a hole in the map.
                retryCurrent = false
                emit(.prompt(target))
            } else {
                advance()
            }
            return
        }

        // Only accept an unambiguous single-button press.
        guard bits != 0, bits.nonzeroBitCount == 1 else { return }
        let index = bits.trailingZeroBitCount
        guard index < 13 else { return }

        if let existing = learned[index], existing != target {
            awaitingRelease = true
            retryCurrent = true
            emit(.rejected(target, conflictsWith: existing))
            return
        }

        learned[index] = target
        awaitingRelease = true
        emit(.learned(target, bit: index))
    }

    private func advance() {
        guard let next = queue.first else {
            current = nil
            emit(.finished(resolvedOrder()))
            return
        }
        queue.removeFirst()
        current = next
        emit(.prompt(next))
    }

    /// Any button never seen keeps its default position, as long as that position was not
    /// claimed by a button that *was* observed.
    public func resolvedOrder() -> [ButtonID] {
        var order = [ButtonID?](repeating: nil, count: 13)
        for (index, button) in learned { order[index] = button }
        var free = (0..<13).filter { order[$0] == nil }
        for button in ButtonID.allCases where !learned.values.contains(button) {
            guard let slot = free.first else { break }
            free.removeFirst()
            order[slot] = button
        }
        let resolved = order.compactMap { $0 }
        return resolved.count == 13 ? resolved : ButtonID.defaultBitOrder
    }
}
