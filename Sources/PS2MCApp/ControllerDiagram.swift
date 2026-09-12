import PS2MCKit
import SwiftUI

/// A drawn gamepad whose parts light up.
///
/// Used in three places with the same geometry: the Status tab (what is pressed right
/// now), calibration (which button to press next), and the mapping wizard (which input is
/// being bound). Sharing one diagram means the thing you are told to press looks exactly
/// like the thing that lights up when you press it.
struct ControllerDiagram: View {
    var state: ControllerState = ControllerState()
    /// Button the user is being asked to press, drawn pulsing.
    var prompt: ButtonID?
    /// D-pad direction being asked for.
    var dpadPrompt: DPadID?
    /// Buttons already dealt with, drawn checked.
    var completed: Set<ButtonID> = []
    var showStickPositions = true

    @State private var pulse = false

    // One coordinate system for the whole diagram: absolute points in this space, origin
    // top-left. Every part is placed with .position, so moving one cannot shift another.
    private let w: CGFloat = 420
    private let h: CGFloat = 250

    private let bodyRect = CGRect(x: 12, y: 58, width: 396, height: 180)
    private let dpadCentre = CGPoint(x: 84, y: 112)
    private let faceCentre = CGPoint(x: 336, y: 112)
    private let leftStick = CGPoint(x: 152, y: 176)
    private let rightStick = CGPoint(x: 268, y: 176)

    var body: some View {
        ZStack(alignment: .topLeading) {
            shell
            shoulders
            dpad
            faceButtons
            systemButtons
            sticks
        }
        .frame(width: w, height: h)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    // MARK: - Chrome

    private var shell: some View {
        RoundedRectangle(cornerRadius: 56)
            .fill(.quaternary.opacity(0.55))
            .overlay(RoundedRectangle(cornerRadius: 56)
                .strokeBorder(.secondary.opacity(0.3)))
            .frame(width: bodyRect.width, height: bodyRect.height)
            .position(x: bodyRect.midX, y: bodyRect.midY)
    }

    private var shoulders: some View {
        let size = CGSize(width: 66, height: 19)
        return ZStack {
            part(.l2, label: "L2", at: CGPoint(x: 86, y: 14), size: size)
            part(.r2, label: "R2", at: CGPoint(x: w - 86, y: 14), size: size)
            part(.l1, label: "L1", at: CGPoint(x: 86, y: 38), size: size)
            part(.r1, label: "R1", at: CGPoint(x: w - 86, y: 38), size: size)
        }
    }

    // MARK: - Inputs

    private var dpad: some View {
        let arm: CGFloat = 20, thick: CGFloat = 19
        let c = dpadCentre
        return ZStack {
            dpadArm(.up, at: CGPoint(x: c.x, y: c.y - (arm + thick) / 2),
                    size: CGSize(width: thick, height: arm))
            dpadArm(.down, at: CGPoint(x: c.x, y: c.y + (arm + thick) / 2),
                    size: CGSize(width: thick, height: arm))
            dpadArm(.left, at: CGPoint(x: c.x - (arm + thick) / 2, y: c.y),
                    size: CGSize(width: arm, height: thick))
            dpadArm(.right, at: CGPoint(x: c.x + (arm + thick) / 2, y: c.y),
                    size: CGSize(width: arm, height: thick))
            RoundedRectangle(cornerRadius: 3)
                .fill(.secondary.opacity(0.2))
                .frame(width: thick, height: thick)
                .position(c)
        }
    }

    private func dpadArm(_ direction: DPadID, at point: CGPoint, size: CGSize) -> some View {
        let lit = state.dpad.contains(direction)
        let asking = dpadPrompt == direction
        return RoundedRectangle(cornerRadius: 4)
            .fill(fill(lit: lit, asking: asking))
            .frame(width: size.width, height: size.height)
            .scaleEffect(asking && pulse ? 1.2 : 1)
            .position(point)
    }

    private var faceButtons: some View {
        // Y top, B right, A bottom, X left — the letter layout on the pad itself.
        let c = faceCentre, r: CGFloat = 29
        return ZStack {
            circleButton(.y, at: CGPoint(x: c.x, y: c.y - r))
            circleButton(.b, at: CGPoint(x: c.x + r, y: c.y))
            circleButton(.a, at: CGPoint(x: c.x, y: c.y + r))
            circleButton(.x, at: CGPoint(x: c.x - r, y: c.y))
        }
    }

    private var systemButtons: some View {
        let size = CGSize(width: 54, height: 16)
        return ZStack {
            part(.select, label: "SELECT", at: CGPoint(x: w / 2 - 34, y: 104), size: size)
            part(.start, label: "START", at: CGPoint(x: w / 2 + 34, y: 104), size: size)
            part(.analog, label: "ANALOG", at: CGPoint(x: w / 2, y: 128),
                 size: CGSize(width: 60, height: 16))
        }
    }

    private var sticks: some View {
        ZStack {
            stick(.l3, at: leftStick, x: state.leftX, y: state.leftY)
            stick(.r3, at: rightStick, x: state.rightX, y: state.rightY)
        }
    }

    // MARK: - Primitives

    private func circleButton(_ id: ButtonID, at point: CGPoint) -> some View {
        let lit = state.buttons.contains(id)
        let asking = prompt == id
        return ZStack {
            Circle()
                .fill(fill(lit: lit, asking: asking))
                .overlay(Circle().strokeBorder(.secondary.opacity(0.35)))
            Text(id.rawValue.uppercased())
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(lit || asking ? Color.white : Color.secondary)
            if completed.contains(id), !asking {
                check.offset(x: 13, y: -13)
            }
        }
        .frame(width: 30, height: 30)
        .scaleEffect(asking && pulse ? 1.22 : 1)
        .position(point)
    }

    private func part(_ id: ButtonID, label: String, at point: CGPoint,
                      size: CGSize) -> some View {
        let lit = state.buttons.contains(id)
        let asking = prompt == id
        return ZStack {
            RoundedRectangle(cornerRadius: size.height / 2)
                .fill(fill(lit: lit, asking: asking))
                .overlay(RoundedRectangle(cornerRadius: size.height / 2)
                    .strokeBorder(.secondary.opacity(0.3)))
            Text(label)
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(lit || asking ? Color.white : Color.secondary)
            if completed.contains(id), !asking {
                check.offset(x: size.width / 2 + 7, y: 0)
            }
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(asking && pulse ? 1.12 : 1)
        .position(point)
    }

    /// A stick well with the live position drawn inside, the cap doubling as L3/R3.
    private func stick(_ id: ButtonID, at point: CGPoint, x: Double, y: Double) -> some View {
        let lit = state.buttons.contains(id)
        let asking = prompt == id
        let well: CGFloat = 52, cap: CGFloat = 25
        let travel = (well - cap) / 2
        return ZStack {
            Circle()
                .fill(.secondary.opacity(0.16))
                .overlay(Circle().strokeBorder(.secondary.opacity(0.3)))
                .frame(width: well, height: well)
            Circle()
                .fill(fill(lit: lit, asking: asking))
                .frame(width: cap, height: cap)
                .offset(x: showStickPositions ? CGFloat(x) * travel : 0,
                        y: showStickPositions ? CGFloat(y) * travel : 0)
            Text(id.rawValue.uppercased())
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(Color.secondary)
                .offset(y: well / 2 + 10)
            if completed.contains(id), !asking {
                check.offset(x: well / 2 - 2, y: -well / 2 + 2)
            }
        }
        .frame(width: well, height: well)
        .scaleEffect(asking && pulse ? 1.14 : 1)
        .position(point)
        .animation(.linear(duration: 0.04), value: x)
        .animation(.linear(duration: 0.04), value: y)
    }

    private var check: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 10, weight: .black))
            .foregroundStyle(.green)
    }

    private func fill(lit: Bool, asking: Bool) -> Color {
        if asking { return .orange }
        if lit { return .accentColor }
        return Color.secondary.opacity(0.28)
    }
}
