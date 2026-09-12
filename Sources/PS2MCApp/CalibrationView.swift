import PS2MCKit
import SwiftUI

/// Guided calibration, driven by the same `ButtonOrderLearner` as `ps2mc calibrate`.
///
/// Runs its own HID reader rather than borrowing the driver's, so calibrating never risks
/// emitting keystrokes into whatever is behind the window.
struct CalibrationView: View {
    /// Renders canned state instead of opening the device. Used to produce the
    /// documentation screenshots, which otherwise could not show a mid-calibration view.
    var preview = false

    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var prompt: ButtonID?
    @State private var log: [String] = []
    @State private var result: [ButtonID]?
    @State private var session: CalibrationSession?
    @State private var error: String?
    @State private var done: Set<ButtonID> = []
    /// Raw button bits, decoded with an identity order so the diagram lights whatever is
    /// physically pressed even before we know which button that bit belongs to.
    @State private var pressedRaw: ControllerState = ControllerState()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Calibrate buttons").font(.title2.weight(.semibold))
            Text("Adapter clones disagree about which report bit each button uses. Press "
                 + "each button as it is named; it advances when you let go.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
            }

            // The diagram highlights the button being asked for and lights whatever is
            // actually pressed, so "press Y" and "Y is down" are the same picture.
            ControllerDiagram(state: pressedRaw, prompt: prompt,
                              completed: done, showStickPositions: false)
                .frame(maxWidth: .infinity)

            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4))
                if let result {
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title).foregroundStyle(.green)
                        Text("Done — \(result.count) buttons mapped").font(.headline)
                    }
                } else if let prompt {
                    VStack(spacing: 4) {
                        Text("Press").font(.caption).foregroundStyle(.secondary)
                        Text(prompt.displayName).font(.title2.weight(.semibold))
                    }
                } else {
                    Text("Waiting for the controller…").foregroundStyle(.secondary)
                }
            }
            .frame(height: 64)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 88)

            HStack {
                Button("Skip this button") { session?.learner.skipCurrent() }
                    .disabled(prompt == nil || result != nil)
                Spacer()
                Button("Cancel") { finish(save: false) }
                Button(result == nil ? "Save what I have" : "Save") { finish(save: true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear(perform: begin)
        .onDisappear { session?.stop() }
    }

    private func begin() {
        if preview {
            prompt = .r1
            done = [.y, .b, .a, .x, .l1]
            pressedRaw.buttons = [.r1]
            log = ["✓ y = bit 0", "✓ b = bit 1", "✓ a = bit 2",
                   "✓ x = bit 3", "✓ l1 = bit 4"]
            return
        }
        // Stop the driver first: calibration means pressing every button, and we do not
        // want those presses reaching the game or the desktop.
        model.stop()

        let learner = ButtonOrderLearner { event in
            Task { @MainActor in
                switch event {
                case .prompt(let button):
                    prompt = button
                case .learned(let button, let bit):
                    log.append("✓ \(button.rawValue) = bit \(bit)")
                    done.insert(button)
                case .rejected(_, let conflict):
                    log.append("↺ that bit is already \(conflict.rawValue) — try another")
                case .finished(let order):
                    prompt = nil
                    result = order
                }
            }
        }
        do {
            session = try CalibrationSession(config: model.config, learner: learner,
                                             onReport: { report in
                Task { @MainActor in
                    // Identity order: bit N lights the Nth button in the canonical list, so
                    // the diagram reflects raw hardware rather than a mapping we are still
                    // in the middle of working out.
                    pressedRaw = ControllerState.decode(
                        report: report, bitOrder: ButtonID.defaultBitOrder) ?? ControllerState()
                }
            })
            learner.begin()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func finish(save: Bool) {
        session?.stop()
        if save {
            model.config.buttonBitOrder = result ?? session?.learner.resolvedOrder()
                ?? model.config.buttonBitOrder
            model.markDirty()
            model.save()
        }
        dismiss()
    }
}

/// A HID reader scoped to calibration, on its own thread.
@MainActor
final class CalibrationSession {
    let learner: ButtonOrderLearner
    private var reader: HIDReader?
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    init(config: Config, learner: ButtonOrderLearner,
         onReport: @escaping ([UInt8]) -> Void) throws {
        self.learner = learner
        let reader = HIDReader(config: config, onReport: { report in
            onReport(report)
            Task { @MainActor in learner.ingest(report: report) }
        }, onConnectionChange: { _, _ in })
        self.reader = reader

        var startError: Error?
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.runLoop = CFRunLoopGetCurrent()
            do { try reader.start() } catch { startError = error }
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "family.theviehmeyers.ps2mc.calibrate"
        self.thread = thread
        thread.start()
        ready.wait()
        if let startError { throw startError }
    }

    func stop() {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            self?.reader?.stop()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
        self.runLoop = nil
        thread = nil
    }
}
