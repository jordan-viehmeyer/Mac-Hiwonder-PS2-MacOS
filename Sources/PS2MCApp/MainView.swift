import PS2MCKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = Tab.status
    @State private var calibrating = false

    enum Tab: String, CaseIterable {
        case status = "Status"
        case bindings = "Bindings"
        case tuning = "Tuning"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()

            Group {
                switch tab {
                case .status: statusTab
                case .bindings: BindingsView()
                case .tuning: TuningView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(minWidth: 700, minHeight: 620)
        .sheet(isPresented: $calibrating) { CalibrationView() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "gamecontroller.fill")
                .font(.title)
                .foregroundStyle(model.status.connected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("ps2mc").font(.title3.weight(.semibold))
                Text(statusLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRunning && model.status.connected {
                Toggle("Muted", isOn: Binding(
                    get: { model.status.suspended },
                    set: { model.setSuspended($0) }))
                    .toggleStyle(.switch)
                    .help("Suspend all output without stopping the driver. "
                          + "The pad's Analog button does the same.")
            }
            Button(model.isRunning ? "Stop" : "Start") { model.toggleRunning() }
                .keyboardShortcut("r")
                .disabled(!model.canRun && !model.isRunning)
                .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var statusLine: String {
        if !model.canRun { return "Permissions needed" }
        if !model.isRunning { return "Stopped" }
        if let message = model.status.message { return message }
        if !model.status.connected { return "Running — waiting for the controller" }
        if model.status.suspended { return "Muted — output suspended" }
        return model.status.deviceName ?? "Running"
    }

    // MARK: - Status tab

    private var statusTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                permissionsCard
                if model.status.connected {
                    ControllerView(state: model.live, config: model.config)
                } else {
                    notConnectedCard
                }
                HStack {
                    Button("Calibrate buttons…") { calibrating = true }
                    Button("Reveal config in Finder") { model.revealConfigInFinder() }
                    Spacer()
                }
            }
            .padding(20)
        }
    }

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Permissions").font(.headline)
            permissionRow(
                title: "Input Monitoring",
                detail: "Required to read the controller.",
                status: model.inputMonitoring,
                action: { model.requestInputMonitoring() },
                pane: "Privacy_ListenEvent")
            permissionRow(
                title: "Accessibility",
                detail: "Required to send keyboard and mouse events.",
                status: model.accessibility,
                action: { model.requestAccessibility() },
                pane: "Privacy_Accessibility")
            if !model.canRun {
                Text("Grant both to PS2MC itself. macOS pins these to the app's location, so "
                     + "keep it in /Applications rather than running it from a download "
                     + "folder or a build directory.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    private func permissionRow(title: String, detail: String, status: Permissions.Status,
                               action: @escaping () -> Void, pane: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: status == .granted
                  ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(status == .granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if status != .granted {
                Button("Request") { action() }.controlSize(.small)
                Button("Open Settings") { Permissions.openSettings(pane: pane) }
                    .controlSize(.small)
            }
        }
    }

    private var notConnectedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Controller not detected", systemImage: "gamecontroller")
                .font(.headline)
            let ids = String(format: "%04x:%04x",
                             model.config.vendorID, model.config.productID)
            Text("""
                • Plug in the USB receiver and switch the pad on.
                • Press the pad's ANALOG button so the receiver pairs.
                • Looking for USB \(ids); any HID gamepad is accepted as a fallback.
                """)
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let error = model.validationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .lineLimit(2)
            } else if model.dirty {
                Text("Unsaved changes").font(.caption).foregroundStyle(.secondary)
            } else if let saved = model.lastSaved {
                Text("Saved \(saved.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reset to defaults") { model.resetToDefaults() }
            Button("Revert") { model.reload() }.disabled(!model.dirty)
            Button("Save") { model.save() }
                .keyboardShortcut("s")
                .disabled(!model.dirty || model.validationError != nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
