import PS2MCKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = Tab.status
    @State private var calibrating = false
    @State private var wizard = false
    @State private var duplicating = false
    @State private var renaming = false
    @State private var confirmDelete = false
    @State private var nameField = ""

    enum Tab: String, CaseIterable {
        case status = "Status"
        case bindings = "Bindings"
        case tuning = "Tuning"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            profileBar
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
        .frame(minWidth: 720, minHeight: 680)
        .sheet(isPresented: $calibrating) { CalibrationView(preview: DocsRenderer.posed != nil) }
        .sheet(isPresented: $wizard) { WizardView(preview: DocsRenderer.posed != nil) }
        .onAppear {
            // `--docs-pose <view>` opens straight onto the view being screenshotted.
            switch DocsRenderer.posed {
            case "bindings": tab = .bindings
            case "tuning": tab = .tuning
            case "calibration": calibrating = true
            case "wizard": wizard = true
            default: break
            }
        }
        .alert("Duplicate profile", isPresented: $duplicating) { nameAlert { 
            model.duplicateActiveProfile(named: nameField) } }
        .alert("Rename profile", isPresented: $renaming) { nameAlert {
            model.renameActiveProfile(to: nameField) } }
        .confirmationDialog("Delete “\(model.activeProfile?.name ?? "")”?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.deleteActiveProfile() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the profile file. It cannot be undone.")
        }
    }

    @ViewBuilder
    private func nameAlert(_ commit: @escaping () -> Void) -> some View {
        TextField("Name", text: $nameField)
        Button("Cancel", role: .cancel) {}
        Button("Save") { commit() }
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
        if !model.fullyGranted { return "Permissions needed to send input" }
        if !model.isRunning { return "Stopped" }
        if let message = model.status.message { return message }
        if !model.status.connected { return "Running — waiting for the controller" }
        if model.status.suspended { return "Muted — output suspended" }
        return model.status.deviceName ?? "Running"
    }

    // MARK: - Profiles

    private var profileBar: some View {
        HStack(spacing: 10) {
            Text("Profile").font(.callout).foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { model.activeProfileID },
                set: { model.selectProfile($0) })) {
                ForEach(model.profiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)

            if model.activeIsReadOnly {
                Label("Read-only", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("The recommended profile is refreshed on upgrade. "
                          + "Duplicate it to make changes.")
            }

            Spacer()

            Button("Duplicate") {
                nameField = (model.activeProfile?.name ?? "Profile") + " copy"
                duplicating = true
            }
            Button("Rename") {
                nameField = model.activeProfile?.name ?? ""
                renaming = true
            }
            .disabled(model.activeIsReadOnly)
            Button("Delete") { confirmDelete = true }
                .disabled(model.activeIsReadOnly || model.profiles.count < 2)
            Button("New from wizard…") { wizard = true }
                .disabled(!model.canReadController)
                .help(model.canReadController ? "Map every control step by step"
                                              : "Needs Input Monitoring")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
    }

    // MARK: - Status tab

    private var statusTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                permissionsCard
                if model.status.connected {
                    ControllerDiagram(state: model.live)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } else {
                    notConnectedCard
                }
                HStack {
                    Button("Calibrate buttons…") { calibrating = true }
                        .disabled(!model.canReadController)
                    Button("Reveal profile in Finder") { model.revealProfilesInFinder() }
                    Spacer()
                }
                if let error = model.profileError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
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
                detail: "Read the controller. Needed for the live view, calibration "
                    + "and the wizard.",
                status: model.inputMonitoring,
                action: { model.requestInputMonitoring() },
                pane: "Privacy_ListenEvent")
            permissionRow(
                title: "Accessibility",
                detail: "Send keyboard and mouse events. Only needed to actually play.",
                status: model.accessibility,
                action: { model.requestAccessibility() },
                pane: "Privacy_Accessibility")
            if !model.fullyGranted {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ps2mc asks for nothing else, and never prompts on its own — use "
                         + "the buttons above. Grant these to PS2MC itself.")
                    // The most common cause of "I granted it and it still says no", and
                    // the one nothing in System Settings hints at.
                    Text(Permissions.staleGrantAdvice)
                    Button("Recheck now") { model.refreshPermissions() }
                        .controlSize(.small)
                        .padding(.top, 2)
                }
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
            Image(systemName: icon(for: status))
                .foregroundStyle(status == .granted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).font(.callout.weight(.medium))
                    // "Not yet requested" is not the same as refused, and showing them
                    // identically is what makes a first launch look broken.
                    if status == .notDetermined {
                        Text("not yet requested")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
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

    private func icon(for status: Permissions.Status) -> String {
        switch status {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "exclamationmark.circle.fill"
        case .notDetermined: return "questionmark.circle.fill"
        }
    }

    private var notConnectedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Controller not detected", systemImage: "gamecontroller")
                .font(.headline)
            ControllerDiagram()
                .frame(maxWidth: .infinity)
                .opacity(0.4)
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
                    .foregroundStyle(.orange).font(.caption).lineLimit(2)
            } else if model.activeIsReadOnly && model.dirty {
                Text("Read-only profile — duplicate it to keep these changes")
                    .font(.caption).foregroundStyle(.orange)
            } else if model.dirty {
                Text("Unsaved changes").font(.caption).foregroundStyle(.secondary)
            } else if let saved = model.lastSaved {
                Text("Saved \(saved.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reset to recommended") { model.resetToRecommended() }
            Button("Revert") { model.revert() }.disabled(!model.dirty)
            if model.activeIsReadOnly {
                Button("Duplicate to save") {
                    nameField = (model.activeProfile?.name ?? "Profile") + " copy"
                    duplicating = true
                }
                .keyboardShortcut("s")
                .disabled(!model.dirty)
            } else {
                Button("Save") { model.save() }
                    .keyboardShortcut("s")
                    .disabled(!model.dirty || model.validationError != nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
