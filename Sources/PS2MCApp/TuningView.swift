import PS2MCKit
import SwiftUI

/// Stick roles and feel. Every control here maps to one config field.
struct TuningView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                rolePicker

                stickSection("Left stick", stick: $model.config.leftStick)
                stickSection("Right stick", stick: $model.config.rightStick)

                VStack(alignment: .leading, spacing: 8) {
                    Text("General").font(.headline)
                    slider("Poll rate", value: $model.config.pollRateHz,
                           range: 60...500, step: 5, unit: "Hz",
                           help: "How often stick position becomes mouse motion. Above the "
                               + "receiver's own 125 Hz on purpose, so motion is spaced more "
                               + "evenly between reports.")
                    Picker("Hotbar", selection: $model.config.hotbarMode) {
                        Text("Scroll wheel").tag(HotbarMode.scroll)
                        Text("Number keys 1–9").tag(HotbarMode.numbers)
                    }
                    .pickerStyle(.radioGroup)
                    .onChange(of: model.config.hotbarMode) { _, _ in model.markDirty() }
                    Text("Scroll lets the game own the slot index, so it cannot drift out of "
                         + "sync. Number keys are deterministic but desync if you also scroll.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
    }

    private var rolePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stick roles").font(.headline)
            HStack(spacing: 30) {
                Picker("Left", selection: $model.config.leftStick.role) {
                    ForEach([StickRole.move, .look, .none], id: \.self) {
                        Text($0.rawValue.capitalized).tag($0)
                    }
                }
                .onChange(of: model.config.leftStick.role) { _, _ in model.markDirty() }
                Picker("Right", selection: $model.config.rightStick.role) {
                    ForEach([StickRole.look, .move, .none], id: \.self) {
                        Text($0.rawValue.capitalized).tag($0)
                    }
                }
                .onChange(of: model.config.rightStick.role) { _, _ in model.markDirty() }
            }
            .frame(maxWidth: 420)
            Button("Swap sticks") {
                let left = model.config.leftStick.role
                model.config.leftStick.role = model.config.rightStick.role
                model.config.rightStick.role = left
                model.markDirty()
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func stickSection(_ title: String, stick: Binding<StickConfig>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title) — \(stick.wrappedValue.role.rawValue)").font(.headline)
            switch stick.wrappedValue.role {
            case .look:
                slider("Sensitivity X", value: stick.look.sensitivityX,
                       range: 400...6000, step: 50, unit: "px/s",
                       help: "macOS truncates mouse deltas to whole pixels, so a slow pan "
                           + "arrives as that many one-pixel steps per second. If it feels "
                           + "steppy, raise this and lower Minecraft's own sensitivity.")
                slider("Sensitivity Y", value: stick.look.sensitivityY,
                       range: 300...5000, step: 50, unit: "px/s")
                slider("Deadzone", value: stick.look.deadzone,
                       range: 0...0.5, step: 0.01, unit: "",
                       help: "Raise this if the camera drifts with the stick at rest.")
                slider("Curve", value: stick.look.exponent,
                       range: 1...3, step: 0.05, unit: "",
                       help: "1.0 is linear. Higher gives finer aim near centre, but widens "
                           + "the slow region where pixel stepping shows.")
                slider("Smoothing", value: stick.look.smoothingMs,
                       range: 0...120, step: 1, unit: "ms",
                       help: "Higher is smoother but less immediate. 0 disables the filter.")
                Toggle("Invert Y", isOn: stick.look.invertY)
                    .onChange(of: stick.wrappedValue.look.invertY) { _, _ in model.markDirty() }
                Toggle("Invert X", isOn: stick.look.invertX)
                    .onChange(of: stick.wrappedValue.look.invertX) { _, _ in model.markDirty() }
                turnRateNote(stick.wrappedValue.look)

            case .move:
                slider("Engage threshold", value: stick.move.threshold,
                       range: 0.1...0.8, step: 0.01, unit: "",
                       help: "How far the stick travels before movement starts, measured "
                           + "radially so every direction engages at the same distance.")
                slider("Release hysteresis", value: stick.move.releaseHysteresis,
                       range: 0...0.3, step: 0.01, unit: "")
                slider("Diagonal width", value: stick.move.directionTolerance,
                       range: 0.1...0.7, step: 0.01, unit: "",
                       help: "0.38 gives eight equal 45° sectors. Lower widens diagonals.")
                slider("Release delay", value: stick.move.releaseDelayMs,
                       range: 0...200, step: 5, unit: "ms",
                       help: "Holds a direction briefly through the dip you get rotating "
                           + "the stick between sectors.")

            case .none:
                Text("This stick is ignored.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Translate sensitivity into something meaningful: how fast a full push turns you.
    private func turnRateNote(_ look: LookBinding) -> some View {
        let turns = look.sensitivityX / 2400
        return Text(String(format:
            "A full push turns about %.2f× per second (≈%.1f s for a 360° turn) "
            + "at Minecraft's default in-game sensitivity.", turns, 1 / max(turns, 0.01)))
            .font(.caption).foregroundStyle(.secondary)
    }

    private func slider(_ label: String, value: Binding<Double>,
                        range: ClosedRange<Double>, step: Double, unit: String,
                        help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.callout).frame(width: 140, alignment: .leading)
                Slider(value: value, in: range, step: step)
                    .onChange(of: value.wrappedValue) { _, _ in model.markDirty() }
                Text(unit.isEmpty
                     ? String(format: "%.2f", value.wrappedValue)
                     : String(format: "%.0f %@", value.wrappedValue, unit))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 74, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
            if let help {
                Text(help).font(.caption2).foregroundStyle(.tertiary)
                    .padding(.leading, 140)
            }
        }
    }
}
