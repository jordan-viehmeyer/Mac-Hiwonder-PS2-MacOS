import PS2MCKit
import SwiftUI

/// Editor for every button and D-pad binding.
///
/// Each row combines a picker for the common actions with a free-text field, because the
/// binding grammar can express more than a menu reasonably can (`combo:shift+w`,
/// `scroll:up*3`). The picker writes into the same string the field shows, so neither is a
/// second source of truth.
struct BindingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("Buttons", rows: ButtonID.allCases.map {
                    Row(id: $0.rawValue, label: $0.displayName, isDPad: false)
                })
                section("D-pad", rows: DPadID.allCases.map {
                    Row(id: $0.rawValue, label: $0.rawValue.capitalized, isDPad: true)
                })

                DisclosureGroup("Binding syntax") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Self.syntaxHelp, id: \.0) { form, meaning in
                            HStack(alignment: .top, spacing: 8) {
                                Text(form)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 150, alignment: .leading)
                                Text(meaning).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.subheadline)
            }
            .padding(20)
        }
    }

    private struct Row: Identifiable {
        let id: String
        let label: String
        let isDPad: Bool
    }

    private func section(_ title: String, rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    Text(row.label)
                        .frame(width: 170, alignment: .leading)
                        .font(.callout)
                    BindingField(spec: binding(for: row), presets: Self.presets)
                }
            }
        }
    }

    /// One binding as a two-way String, so edits land straight in the config.
    private func binding(for row: Row) -> Binding<String> {
        Binding(
            get: {
                (row.isDPad ? model.config.dpad[row.id] : model.config.buttons[row.id]) ?? "none"
            },
            set: { newValue in
                if row.isDPad { model.config.dpad[row.id] = newValue }
                else { model.config.buttons[row.id] = newValue }
                model.markDirty()
            }
        )
    }

    static let presets: [(String, String)] = [
        ("Unbound", "none"),
        ("Jump (Space)", "key:space"),
        ("Sneak — hold", "key:shift"),
        ("Sneak — toggle", "key:shift@toggle"),
        ("Sprint — toggle", "key:control@toggle"),
        ("Inventory (E)", "key:e"),
        ("Drop (Q)", "key:q@repeat"),
        ("Off-hand swap (F)", "key:f"),
        ("Chat (T)", "key:t"),
        ("Player list (Tab)", "key:tab"),
        ("Pause (Esc)", "key:escape"),
        ("Perspective (F5)", "key:f5"),
        ("Destroy — left click", "mouse:left"),
        ("Place — right click", "mouse:right"),
        ("Pick block — middle click", "mouse:middle"),
        ("Hotbar next", "hotbar:next"),
        ("Hotbar previous", "hotbar:prev"),
        ("Scroll up", "scroll:up"),
        ("Scroll down", "scroll:down"),
        ("Mute driver", "special:toggleEngine"),
    ]

    static let syntaxHelp: [(String, String)] = [
        ("key:w", "hold W while the button is held"),
        ("key:space@tap", "one press per button press"),
        ("key:shift@toggle", "latch on until pressed again"),
        ("key:q@repeat", "press, then auto-repeat while held"),
        ("combo:shift+w", "hold Shift and W together"),
        ("mouse:left", "hold left click"),
        ("scroll:up*3", "three wheel notches up"),
        ("hotbar:next / :prev", "step one hotbar slot"),
        ("hotbar:5", "jump to hotbar slot 5"),
        ("special:toggleEngine", "suspend or resume all output"),
        ("none", "unbound"),
    ]
}

/// A preset menu and a text field over the same underlying string.
private struct BindingField: View {
    @Binding var spec: String
    let presets: [(String, String)]

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(presets, id: \.1) { name, value in
                    Button(name) { spec = value }
                }
            } label: {
                Image(systemName: "list.bullet")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help("Common actions")

            TextField("none", text: $spec)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: 260)
        }
    }
}
