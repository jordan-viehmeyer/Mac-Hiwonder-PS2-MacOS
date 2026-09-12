import Combine
import Foundation
import PS2MCKit
import SwiftUI

/// The app's single source of truth: the loaded config, the running driver, and the
/// permission state the UI reacts to.
@MainActor
final class AppModel: ObservableObject {
    @Published var config: Config
    @Published var status = DriverController.Status()
    @Published var live = ControllerState()
    @Published var inputMonitoring: Permissions.Status = .unknown
    @Published var accessibility: Permissions.Status = .unknown
    /// Set when the config on screen has edits that are not on disk yet.
    @Published var dirty = false
    /// Surfaced next to the Save button when a binding will not parse.
    @Published var validationError: String?
    @Published var lastSaved: Date?

    private var driver: DriverController?
    private var permissionTimer: Timer?

    var isRunning: Bool { status.running }
    var canRun: Bool { inputMonitoring == .granted && accessibility == .granted }

    init() {
        config = (try? Config.load()) ?? Config()
        refreshPermissions()
        // TCC changes arrive with no notification, so the switches in System Settings only
        // show up here if we look again periodically.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refreshPermissions() }
        }

        // Quitting must release whatever is held, or the last key pressed stays down in
        // whatever app had focus.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func refreshPermissions() {
        inputMonitoring = Permissions.inputMonitoring()
        accessibility = Permissions.accessibility()
    }

    func requestInputMonitoring() {
        Permissions.requestInputMonitoring()
        refreshPermissions()
    }

    func requestAccessibility() {
        _ = Permissions.accessibility(prompt: true)
        refreshPermissions()
    }

    // MARK: - Driver lifecycle

    func start() {
        guard driver == nil else { return }
        validationError = nil
        let driver = DriverController(config: config, configPath: Config.path)
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

    func setSuspended(_ suspended: Bool) {
        driver?.setSuspended(suspended)
    }

    /// Restart so edits take effect. The engine resolves bindings once at construction, so
    /// there is no way to apply them to a live instance without rebuilding it.
    func applyChanges() {
        guard isRunning else { return }
        stop()
        start()
    }

    // MARK: - Config

    func markDirty() {
        dirty = true
        // Validate as you type so a bad binding is visible immediately rather than at save.
        do {
            try DriverController.validate(config, source: Config.path)
            validationError = nil
        } catch {
            validationError = error.localizedDescription
        }
    }

    func save() {
        do {
            try DriverController.validate(config, source: Config.path)
            try config.save()
            dirty = false
            lastSaved = Date()
            validationError = nil
            applyChanges()
        } catch {
            validationError = error.localizedDescription
        }
    }

    func reload() {
        config = (try? Config.load()) ?? Config()
        dirty = false
        validationError = nil
        applyChanges()
    }

    func resetToDefaults() {
        config = Config()
        markDirty()
    }

    func revealConfigInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Config.path])
    }
}
