import PS2MCKit
import SwiftUI

/// Live view of the pad: both sticks and every button, lit as they are pressed.
///
/// This is the fastest way to answer the two questions that come up constantly — is the
/// pad actually reaching the Mac, and is the button order calibrated correctly — without
/// dropping to the terminal.
struct ControllerView: View {
    let state: ControllerState
    let config: Config

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 28) {
                StickView(x: state.leftX, y: state.leftY,
                          label: "Left", role: config.leftStick.role)
                StickView(x: state.rightX, y: state.rightY,
                          label: "Right", role: config.rightStick.role)
            }

            HStack(alignment: .top, spacing: 24) {
                buttonGroup("Face", [.y, .b, .a, .x])
                buttonGroup("Shoulders", [.l1, .r1, .l2, .r2])
                buttonGroup("Sticks", [.l3, .r3])
                buttonGroup("System", [.select, .start, .analog])
                dpadGroup
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    private func buttonGroup(_ title: String, _ buttons: [ButtonID]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ForEach(buttons, id: \.self) { button in
                Pill(text: button.rawValue.uppercased(), lit: state.buttons.contains(button))
            }
        }
    }

    private var dpadGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("D-pad").font(.caption).foregroundStyle(.secondary)
            ForEach(DPadID.allCases, id: \.self) { direction in
                Pill(text: direction.rawValue.capitalized,
                     lit: state.dpad.contains(direction))
            }
        }
    }
}

private struct Pill: View {
    let text: String
    let lit: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .frame(width: 62, height: 20)
            .background(lit ? Color.accentColor : Color.secondary.opacity(0.18),
                        in: Capsule())
            .foregroundStyle(lit ? Color.white : Color.secondary)
    }
}

/// A stick as a dot in a circle, with the deadzone drawn so it is obvious whether a
/// resting stick sits inside it — the usual cause of phantom camera drift.
private struct StickView: View {
    let x: Double
    let y: Double
    let label: String
    let role: StickRole

    private let size: CGFloat = 96

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().strokeBorder(.secondary.opacity(0.35), lineWidth: 1)
                Circle()
                    .fill(.secondary.opacity(0.12))
                    .frame(width: size * 0.2, height: size * 0.2)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 13, height: 13)
                    .offset(x: CGFloat(x) * size / 2 * 0.86,
                            y: CGFloat(y) * size / 2 * 0.86)
            }
            .frame(width: size, height: size)
            .animation(.linear(duration: 0.03), value: x)
            .animation(.linear(duration: 0.03), value: y)

            Text(label).font(.caption.weight(.medium))
            Text(role.rawValue).font(.caption2).foregroundStyle(.secondary)
            Text(String(format: "%+.2f, %+.2f", x, y))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }
}
