import Combine
import Foundation
import PS2MCKit
import SwiftUI

/// The app's single source of truth: the profile list, the loaded config, the running
/// driver, and the permission state the UI reacts to.
@MainActor
final class AppModel: ObservableObject {
    @Published var config: Config
    @Published var profiles: [ProfileStore.Profile] = []
    @Published var activeProfileID: String
    @Published var status = DriverController.Status()
    @Published var live = ControllerState()
    @Published var inputMonitoring: Permissions.Status = .notDetermined
    @Published var accessibility: Permissions.Status = .notDetermined
    @Published var dirty = false
    @Published var validationError: String?
    @Published var profileError: String?
    @Published var lastSaved: Date?
    /// Set only by the documentation renderer to pick which tab to capture.
    @Published var previewTab: MainView.Tab?

    private let store = ProfileStore.shared
    private var driver: DriverController?
    private var permissionTimer: Timer?

    var isRunning: Bool { status.running }

    /// Sending keystrokes needs Accessibility; *reading* the pad does not.
    ///
    /// A permission that has merely never been requested does not block the attempt — it
    /// will prompt, and refusing to even try would strand anyone whose state reads as
    /// undetermined. Only an explicit denial disables the button.
    var canRun: Bool { !inputMonitoring.blocksUse && !accessibility.blocksUse }
    /// Calibration, the live view and the wizard only read the controller, so they work
    /// with Input Monitoring alone. Nothing asks for Accessibility until you press Start.
    var canReadController: Bool { !inputMonitoring.blocksUse }
    /// True once everything needed to play is actually in place.
    var fullyGranted: Bool { inputMonitoring.isGranted && accessibility.isGranted }

    var activeProfile: ProfileStore.Profile? {
        profiles.first { $0.id == activeProfileID }
    }
    /// The shipped profile is read-only so it can be refreshed on upgrade without
    /// clobbering edits; the UI offers Duplicate instead of Save.
    var activeIsReadOnly: Bool { activeProfile?.isBuiltIn ?? false }

    init() {
        activeProfileID = store.activeID
        config = store.loadActive()
        profiles = store.profiles
        refreshPermissions()

        // Documentation mode shows the app as someone with a working setup sees it:
        // permissions granted, pad connected, sticks in use. The polling timer is skipped
        // so it cannot overwrite that a moment later.
        if DocsRenderer.posed != nil {
            applyDocumentationState()
        } else {
            // TCC changes arrive with no notification, so the switches in System Settings
            // only show up here if we look again periodically. The timer has to be in
            // .common mode: the default mode stops firing while a menu is tracking or a
            // sheet is up, which is exactly when someone is fiddling with permissions.
            let timer = Timer(timeInterval: 1.5, repeats: true) { _ in
                Task { @MainActor [weak self] in self?.refreshPermissions() }
            }
            RunLoop.main.add(timer, forMode: .common)
            permissionTimer = timer

            // Granting happens in System Settings, so the moment this app comes back to
            // the front is the single most likely instant for the answer to have changed.
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPermissions() }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    /// Populate plausible state for screenshots. Never starts the driver.
    private func applyDocumentationState() {
        inputMonitoring = .granted
        accessibility = .granted
        status.running = true
        status.connected = true
        status.deviceName = "USB WirelessGamepad (2563:0575)"
        live = AppModel.demoState
        config = Config.minecraftRecommended
        if let recommended = profiles.first(where: { $0.isBuiltIn }) {
            activeProfileID = recommended.id
        }
    }

    // MARK: - Permissions

    /// Never prompts. The prompt is a deliberate act behind a button, so simply opening
    /// the app does not throw a system dialog at you.
    func refreshPermissions() {
        inputMonitoring = Permissions.inputMonitoring()
        accessibility = Permissions.accessibility()
    }

    func requestInputMonitoring() {
        Permissions.requestInputMonitoring()
        refreshPermissions()
        // The prompt is answered outside this process, so the answer arrives after the
        // call returns. Look again shortly rather than leaving a stale "not granted".
        recheckShortly()
    }

    func requestAccessibility() {
        Permissions.requestAccessibility()
        refreshPermissions()
        recheckShortly()
    }

    private func recheckShortly() {
        for delay in [0.4, 1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.refreshPermissions() }
            }
        }
    }

    // MARK: - Profiles

    func reloadProfiles() {
        store.reload()
        profiles = store.profiles
    }

    func selectProfile(_ id: String) {
        guard id != activeProfileID else { return }
        // Documentation mode must not persist anything: taking screenshots should never
        // change which profile the user actually plays with.
        if DocsRenderer.posed == nil { store.setActive(id) }
        activeProfileID = id
        config = store.load(id: id)
        dirty = false
        validationError = nil
        profileError = nil
        applyChanges()
    }

    func duplicateActiveProfile(named name: String) {
        do {
            let created = try store.create(name: name, from: config)
            reloadProfiles()
            selectProfile(created.id)
            profileError = nil
        } catch {
            profileError = error.localizedDescription
        }
    }

    func deleteActiveProfile() {
        do {
            try store.delete(id: activeProfileID)
            reloadProfiles()
            activeProfileID = store.activeID
            config = store.loadActive()
            dirty = false
            applyChanges()
        } catch {
            profileError = error.localizedDescription
        }
    }

    func renameActiveProfile(to name: String) {
        do {
            try store.rename(id: activeProfileID, to: name)
            reloadProfiles()
            activeProfileID = store.activeID
            profileError = nil
        } catch {
            profileError = error.localizedDescription
        }
    }

    // MARK: - Driver lifecycle

    func start() {
        guard driver == nil else { return }
        validationError = nil
        let driver = DriverController(config: config, configPath: store.url(for: activeProfileID))
        driver.onStatusChange = { [weak self] status in
            Task { @MainActor in self?.status = status }
        }
        driver.onSnapshot = { [weak self] state in
            Task { @MainActor in self?.live = state }
        }
        do {
            try driver.start()
            self.driver = driver
        } catch {
            validationError = error.localizedDescription
        }
    }

    func stop() {
        driver?.stop()
        driver = nil
        status = DriverController.Status()
        live = ControllerState()
    }

    func toggleRunning() { isRunning ? stop() : start() }

    func setSuspended(_ suspended: Bool) { driver?.setSuspended(suspended) }

    /// Restart so edits take effect. The engine resolves bindings once at construction, so
    /// there is no way to apply them to a live instance without rebuilding it.
    func applyChanges() {
        guard isRunning else { return }
        stop()
        start()
    }

    // MARK: - Config editing

    func markDirty() {
        dirty = true
        // Validate as you type so a bad binding is visible immediately rather than at save.
        do {
            try DriverController.validate(config, source: store.url(for: activeProfileID))
            validationError = nil
        } catch {
            validationError = error.localizedDescription
        }
    }

    func save() {
        do {
            try DriverController.validate(config, source: store.url(for: activeProfileID))
            try store.save(config, id: activeProfileID)
            dirty = false
            lastSaved = Date()
            validationError = nil
            applyChanges()
        } catch {
            validationError = error.localizedDescription
        }
    }

    func revert() {
        config = store.load(id: activeProfileID)
        dirty = false
        validationError = nil
        applyChanges()
    }

    func resetToRecommended() {
        config = Config.minecraftRecommended
        markDirty()
    }

    func revealProfilesInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([store.url(for: activeProfileID)])
    }
}
