import Foundation
import PS2MCKit

/// Terminal front end for `ButtonOrderLearner`.
///
/// The state machine lives in the library so this and the app's calibration sheet cannot
/// drift apart; everything here is presentation and the decision to save.
final class Calibrator {
    private var config: Config
    private let configPath: URL
    private var learner: ButtonOrderLearner?
    private var stdinSource: DispatchSourceRead?
    private var started = false

    init(config: Config, configPath: URL) {
        self.config = config
        self.configPath = configPath
    }

    func begin() {
        guard !started else { return }
        started = true
        print("""
            Calibration — press each button as it is named.

            It advances on its own when you release the button.
            If your pad has no such button, press Return here to skip it.
            Ctrl-C aborts and leaves the config untouched.

            """)
        watchStandardInput()

        learner = ButtonOrderLearner { [weak self] event in
            guard let self else { return }
            switch event {
            case .prompt(let button):
                print("  → press \(button.displayName)")
            case .learned(let button, let bit):
                print("     ✓ \(button.rawValue) = bit \(bit)")
            case .rejected(_, let conflict):
                print("     ↺ that bit is already \(conflict.rawValue) — press a different button")
            case .finished(let order):
                self.finish(order)
            }
            fflush(stdout)
        }
        learner?.begin()
    }

    func ingest(report: [UInt8]) {
        learner?.ingest(report: report)
    }

    /// Return on stdin skips the button currently being asked for.
    private func watchStandardInput() {
        let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 256)
            guard read(STDIN_FILENO, &buffer, buffer.count) > 0, let self else { return }
            print("     – skipped")
            self.learner?.skipCurrent()
        }
        source.resume()
        stdinSource = source
    }

    private func finish(_ order: [ButtonID]) {
        stdinSource?.cancel()
        config.buttonBitOrder = order
        do {
            try config.save(to: configPath)
            print("""

                Saved button order to \(configPath.path)

                  \(order.enumerated().map { "\($0.offset):\($0.element.rawValue)" }
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
