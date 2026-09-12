import PS2MCKit
import SwiftUI

/// Step-by-step mapping: for each controller input, press the key you want it to send.
///
/// Ends at Save As rather than overwriting anything, so experimenting with a layout can
/// never cost you the one you already play with.
struct WizardView: View {
    /// Renders canned state for the documentation screenshots.
    var preview = false

    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @StateObject private var capture = KeyCapture()
    @State private var step = 0
    @State private var draft: [Step: String] = [:]
    @State private var mode: ActionMode = .hold
    @State private var saving = false
    @State private var name = ""
    @State private var error: String?

    /// Every bindable input, in the order the wizard walks them: the things you use most
    /// first, so quitting half-way still leaves a usable profile.
    enum Step: Hashable, CaseIterable {
        case button(ButtonID), dpad(DPadID)

        static var allCases: [Step] {
            let buttons: [ButtonID] = [.l2, .r2, .l1, .r1, .a, .b, .x, .y,
                                       .l3, .r3, .select, .start, .analog]
            return buttons.map { .button($0) } + DPadID.allCases.map { .dpad($0) }
        }

        var label: String {
            switch self {
            case .button(let id): return id.displayName
            case .dpad(let id): return "D-pad \(id.rawValue)"
            }
        }
    }

    private var steps: [Step] { Step.allCases }
    private var current: Step? { step < steps.count ? steps[step] : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            diagram
            if saving { saveForm } else { captureArea }
            Spacer(minLength: 0)
            controls
        }
        .padding(22)
        .frame(width: 560)
        .onAppear {
            guard preview else { return }
            step = 4
            draft = [.button(.l2): "mouse:left", .button(.r2): "mouse:right",
                     .button(.l1): "hotbar:prev", .button(.r1): "hotbar:next",
                     .button(.a): "key:space"]
        }
        .onDisappear { capture.stop() }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(saving ? "Save your mapping" : "Mapping wizard")
                .font(.title2.weight(.semibold))
            Text(saving
                 ? "This is saved as a new profile. Nothing you already use is changed."
                 : "Press the key, mouse button or scroll you want this control to send. "
                   + "Modifiers held with a key become a combo.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var diagram: some View {
        ControllerDiagram(
            state: model.live,
            prompt: { if case .button(let id) = current { return id } else { return nil } }(),
            dpadPrompt: { if case .dpad(let id) = current { return id } else { return nil } }(),
            completed: Set(draft.keys.compactMap {
                if case .button(let id) = $0 { return id } else { return nil }
            }),
            showStickPositions: false
        )
        .frame(maxWidth: .infinity)
    }

    private var captureArea: some View {
        VStack(spacing: 10) {
            if let current {
                Text("\(step + 1) of \(steps.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(current.label).font(.title3.weight(.semibold))

                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(capture.capturing ? Color.orange.opacity(0.15)
                                                : Color.secondary.opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(capture.capturing ? .orange : .secondary.opacity(0.3),
                                          lineWidth: capture.capturing ? 2 : 1))
                    if capture.capturing {
                        Text("Listening — press a key…").foregroundStyle(.orange)
                    } else if let spec = draft[current] {
                        Text(spec).font(.system(size: 13, design: .monospaced))
                    } else {
                        Text("Not set").foregroundStyle(.secondary)
                    }
                }
                .frame(height: 44)
                .onTapGesture { beginCapture() }

                Picker("Behaviour", selection: $mode) {
                    Text("Hold").tag(ActionMode.hold)
                    Text("Tap").tag(ActionMode.tap)
                    Text("Toggle").tag(ActionMode.toggle)
                    Text("Repeat").tag(ActionMode.repeatWhileHeld)
                }
                .pickerStyle(.segmented)
                .onChange(of: mode) { _, _ in reapplyMode() }

                Text(modeHelp).font(.caption).foregroundStyle(.secondary)
                    .frame(height: 28).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modeHelp: String {
        switch mode {
        case .hold: return "Held down for as long as the controller button is held. What movement and mining want."
        case .tap: return "One press per button press, however long you hold it."
        case .toggle: return "Latches on until pressed again. Good for sneak and sprint."
        case .repeatWhileHeld: return "Presses repeatedly while held. Good for dropping a whole stack."
        }
    }

    private var saveForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Profile name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            Text("\(draft.count) of \(steps.count) controls mapped. Anything you skipped "
                 + "keeps the recommended default.")
                .font(.caption).foregroundStyle(.secondary)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
            }
        }
    }

    private var controls: some View {
        HStack {
            if saving {
                Button("Back") { saving = false }
            } else {
                Button("Skip") { advance() }
                Button("Clear") {
                    if let current { draft[current] = nil }
                }
                .disabled(current.map { draft[$0] == nil } ?? true)
            }
            Spacer()
            Button("Cancel") { dismiss() }
            if saving {
                Button("Save As") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            } else {
                Button(step == steps.count - 1 ? "Finish" : "Next") { advance() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Behaviour

    private func beginCapture() {
        guard let current else { return }
        capture.begin { spec in
            draft[current] = applyMode(spec, mode)
        }
    }

    /// Modes only apply to keys and mouse buttons; scroll and hotbar have no held state.
    private func applyMode(_ spec: String, _ mode: ActionMode) -> String {
        let base = spec.split(separator: "@").first.map(String.init) ?? spec
        guard base.hasPrefix("key:") || base.hasPrefix("combo:") || base.hasPrefix("mouse:"),
              mode != .hold else { return base }
        return "\(base)@\(mode.rawValue)"
    }

    private func reapplyMode() {
        guard let current, let existing = draft[current] else { return }
        draft[current] = applyMode(existing, mode)
    }

    private func advance() {
        capture.stop()
        if step < steps.count - 1 {
            step += 1
            mode = .hold
            // Start listening immediately: the whole point is to press keys, not to click
            // a field first each time.
            beginCapture()
        } else {
            saving = true
            name = suggestedName()
        }
    }

    private func suggestedName() -> String {
        let existing = Set(ProfileStore.shared.profiles.map(\.name))
        var candidate = "My Mapping"
        var n = 2
        while existing.contains(candidate) {
            candidate = "My Mapping \(n)"
            n += 1
        }
        return candidate
    }

    private func commit() {
        // Start from the recommended mapping so skipped controls stay useful rather than
        // becoming dead buttons.
        var config = Config.minecraftRecommended
        for (step, spec) in draft {
            switch step {
            case .button(let id): config.buttons[id.rawValue] = spec
            case .dpad(let id): config.dpad[id.rawValue] = spec
            }
        }
        do {
            try DriverController.validate(config)
            let profile = try ProfileStore.shared.create(name: name, from: config)
            model.reloadProfiles()
            model.selectProfile(profile.id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
