import CoreGraphics
import Foundation

/// Owns the running driver: the HID reader, the engine, and the tick timer.
///
/// Everything runs on a dedicated thread with its own run loop rather than on whatever
/// thread started it. In the GUI that keeps a 250 Hz tick off the main thread, where it
/// would compete with layout and rendering; in the CLI it means `start()` returns instead
/// of blocking. Callbacks are delivered on the main queue so observers can touch UI
/// directly without hopping themselves.
public final class DriverController {
    public struct Status: Equatable {
        public var running = false
        public var connected = false
        public var suspended = false
        public var deviceName: String?
        public var message: String?

        public init() {}
    }

    /// Called on the main queue whenever `status` changes.
    public var onStatusChange: ((Status) -> Void)?
    /// Called on the main queue with each decoded report, throttled to `snapshotHz`.
    /// Used by the live controller view; leave nil when nothing is watching.
    public var onSnapshot: ((ControllerState) -> Void)?
    /// How often snapshots are delivered. Far below the tick rate: this drives a UI.
    public var snapshotHz: Double = 30

    private(set) var status = Status() {
        didSet {
            guard status != oldValue else { return }
            let snapshot = status
            DispatchQueue.main.async { [weak self] in self?.onStatusChange?(snapshot) }
        }
    }

    private let config: Config
    private let configPath: URL?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var reader: HIDReader?
    private var engine: Engine?
    private var timer: CFRunLoopTimer?
    private var lastSnapshot = Date.distantPast
    private let lock = NSLock()

    public init(config: Config, configPath: URL? = nil) {
        self.config = config
        self.configPath = configPath
    }

    /// Validate the configuration without starting anything, so a bad binding surfaces in
    /// the UI as an error next to the field rather than as a driver that silently refuses
    /// to run.
    public static func validate(_ config: Config, source: URL? = nil) throws {
        _ = try config.resolveBindings(source: source)
    }

    public func start() throws {
        guard thread == nil else { return }
        // Build the engine on the caller's thread so a binding error is thrown here,
        // rather than disappearing into the background thread.
        let engine = try Engine(config: config, synth: EventSynth(),
                                verbose: false, source: configPath)
        self.engine = engine

        let thread = Thread { [weak self] in self?.runLoopMain() }
        thread.name = "family.theviehmeyers.ps2mc.driver"
        // The tick drives mouse motion; anything less than the highest priority lets it be
        // preempted, which shows up directly as uneven camera movement.
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        status.running = true
    }

    public func stop() {
        guard let runLoop else {
            thread = nil
            status = Status()
            return
        }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            guard let self else { return }
            self.engine?.releaseEverything()
            if let timer = self.timer { CFRunLoopTimerInvalidate(timer) }
            self.reader?.stop()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
        self.runLoop = nil
        thread = nil
        status = Status()
    }

    public func setSuspended(_ suspended: Bool) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            self?.engine?.setSuspended(suspended)
            self?.status.suspended = suspended
        }
        CFRunLoopWakeUp(runLoop)
    }

    // MARK: - Driver thread

    private func runLoopMain() {
        runLoop = CFRunLoopGetCurrent()

        let reader = HIDReader(config: config, onReport: { [weak self] report in
            guard let self, let engine = self.engine else { return }
            engine.ingest(report: report)
            self.publishSnapshot(report)
        }, onConnectionChange: { [weak self] connected, description in
            guard let self else { return }
            self.status.connected = connected
            self.status.deviceName = connected ? description : nil
            self.status.message = connected ? nil : description
            if !connected { self.engine?.handleDisconnect() }
        })
        self.reader = reader

        do {
            try reader.start()
        } catch {
            status.message = error.localizedDescription
            status.running = false
            return
        }

        let interval = 1.0 / config.pollRateHz
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + interval, interval, 0, 0
        ) { [weak self] _ in
            self?.engine?.tick()
            // The engine owns the suspend latch, since the pad's Analog button can flip it
            // without the UI being involved. Mirror it back so the menu bar stays honest.
            if let engine = self?.engine, engine.suspended != self?.status.suspended {
                self?.status.suspended = engine.suspended
            }
        }
        self.timer = timer
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .defaultMode)

        CFRunLoopRun()
    }

    private func publishSnapshot(_ report: [UInt8]) {
        guard onSnapshot != nil else { return }
        let now = Date()
        lock.lock()
        let due = now.timeIntervalSince(lastSnapshot) >= 1 / snapshotHz
        if due { lastSnapshot = now }
        lock.unlock()
        guard due,
              let state = ControllerState.decode(report: report, bitOrder: config.buttonBitOrder)
        else { return }
        DispatchQueue.main.async { [weak self] in self?.onSnapshot?(state) }
    }
}
