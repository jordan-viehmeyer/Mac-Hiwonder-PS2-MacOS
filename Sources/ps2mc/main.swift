import CoreGraphics
import Darwin
import Foundation

let version = "1.0.0"

func printUsage() {
    print("""
    ps2mc \(version) — HiWonder PS2 wireless controller driver for macOS 26+
    Maps the pad to keyboard and mouse events, tuned for Minecraft.

    USAGE
      ps2mc <command> [options]

    COMMANDS
      run            Start the driver (default command)
      monitor        Print live controller state; useful for checking wiring
      calibrate      Learn which bit each button occupies and save it to the config
      permissions    Check — and offer to request — the required macOS permissions
      config         Print the active config, or its path with --path
      keys           List every key name accepted in bindings
      selftest       Verify decoding, bindings and config handling
      version        Print the version

    OPTIONS
      --config <path>   Use an alternate config file
      --quiet           Suppress the startup banner and event log
      --raw             (monitor) Also print raw report bytes
      --help, -h        Show this message

    FIRST RUN
      ps2mc permissions     grant Input Monitoring and Accessibility
      ps2mc calibrate       teach it your pad's button order
      ps2mc run             play

    Config lives at \(Config.path.path)
    """)
}

// MARK: - Argument parsing

var arguments = Array(CommandLine.arguments.dropFirst())
var command = "run"
if let first = arguments.first, !first.hasPrefix("-") {
    command = first.lowercased()
    arguments.removeFirst()
}

var configPath = Config.path
var quiet = false
var showRaw = false
var showPath = false

var index = 0
while index < arguments.count {
    switch arguments[index] {
    case "--config":
        index += 1
        guard index < arguments.count else {
            FileHandle.standardError.write("ps2mc: --config needs a path\n".data(using: .utf8)!)
            exit(2)
        }
        configPath = URL(fileURLWithPath: (arguments[index] as NSString).expandingTildeInPath)
    case "--quiet", "-q": quiet = true
    case "--raw": showRaw = true
    case "--path": showPath = true
    case "--help", "-h": printUsage(); exit(0)
    default:
        FileHandle.standardError.write(
            "ps2mc: unknown option '\(arguments[index])'\n".data(using: .utf8)!)
        exit(2)
    }
    index += 1
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("ps2mc: \(message)\n".data(using: .utf8)!)
    exit(1)
}

func loadConfig() -> Config {
    do { return try Config.load(from: configPath) }
    catch { fail("could not read config — \(error.localizedDescription)") }
}

// MARK: - Commands that do not need the device

switch command {
case "help": printUsage(); exit(0)
case "version": print("ps2mc \(version)"); exit(0)
case "keys":
    print("Key names accepted in bindings (e.g. key:space, combo:shift+w):\n")
    let names = Keycodes.allNames
    for row in stride(from: 0, to: names.count, by: 5) {
        let slice = names[row..<min(row + 5, names.count)]
        print("  " + slice.map { $0.padding(toLength: 16, withPad: " ", startingAt: 0) }
            .joined().trimmingCharacters(in: .whitespaces))
    }
    exit(0)
case "selftest":
    exit(SelfTest.run())
case "permissions":
    exit(Permissions.report(requesting: true) ? 0 : 1)
case "config":
    if showPath { print(configPath.path); exit(0) }
    let config = loadConfig()
    do {
        _ = try config.resolveBindings(source: configPath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(data: try encoder.encode(config), encoding: .utf8) ?? "")
    } catch {
        fail(error.localizedDescription)
    }
    exit(0)
case "run", "monitor", "calibrate":
    break
default:
    FileHandle.standardError.write("ps2mc: unknown command '\(command)'\n".data(using: .utf8)!)
    printUsage()
    exit(2)
}

// MARK: - Device-backed commands

let config = loadConfig()

/// Holds everything the run loop touches. A class (rather than loose globals) keeps the
/// C-callback closures capturing one stable reference.
final class Session {
    let config: Config
    let synth = EventSynth()
    var engine: Engine?
    var calibrator: Calibrator?
    var reader: HIDReader?
    var timer: CFRunLoopTimer?
    var sawDevice = false

    init(config: Config) { self.config = config }

    func shutdown() {
        engine?.releaseEverything()
        if let timer { CFRunLoopTimerInvalidate(timer) }
        reader?.stop()
    }
}

let session = Session(config: config)

func note(_ message: String) {
    guard !quiet else { return }
    print(message)
    fflush(stdout)
}

// Permissions are checked before anything opens, because both failure modes look like
// "the controller does nothing" from the outside.
if command == "run" {
    if Permissions.inputMonitoring() != .granted || Permissions.accessibility() != .granted {
        _ = Permissions.report(requesting: true)
        fail("missing permissions — see above, then run `ps2mc run` again")
    }
} else if command == "monitor" || command == "calibrate" {
    if Permissions.inputMonitoring() != .granted {
        Permissions.requestInputMonitoring()
        if Permissions.inputMonitoring() != .granted {
            _ = Permissions.report(requesting: false)
            fail("Input Monitoring is required to read the controller")
        }
    }
}

switch command {
case "run":
    do {
        session.engine = try Engine(config: config, synth: session.synth,
                                    verbose: !quiet, source: configPath)
    } catch {
        fail(error.localizedDescription)
    }
case "calibrate":
    session.calibrator = Calibrator(config: config, configPath: configPath)
default:
    break
}

// Release held keys on Ctrl-C. Without this, quitting mid-stride leaves W latched down.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let signalQueue = DispatchQueue(label: "ps2mc.signals")
// Sources must outlive this scope or they are cancelled the moment they go out of it.
var signalSources: [DispatchSourceSignal] = []
for number in [SIGINT, SIGTERM] {
    let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
    source.setEventHandler {
        session.shutdown()
        print("\nps2mc: stopped.")
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

let reader = HIDReader(config: config, onReport: { report in
    switch command {
    case "run":
        session.engine?.ingest(report: report)
    case "monitor":
        Monitor.render(report: report, config: config, raw: showRaw)
    case "calibrate":
        session.calibrator?.ingest(report: report)
    default:
        break
    }
}, onConnectionChange: { connected, description in
    if connected {
        session.sawDevice = true
        note("🎮 connected: \(description)")
        if command == "calibrate" { session.calibrator?.begin() }
    } else {
        note("⚠️  \(description)")
        session.engine?.handleDisconnect()
    }
})
session.reader = reader

do { try reader.start() } catch { fail(error.localizedDescription) }

switch command {
case "run":
    note("""
        ps2mc \(version) running.
          left stick  → \(config.leftStick.role.rawValue)
          right stick → \(config.rightStick.role.rawValue)
          hotbar mode → \(config.hotbarMode.rawValue)
          config      → \(configPath.path)
        Press Ctrl-C to stop. Press the pad's Analog button to mute output.
        """)

    // A fixed-rate tick drives mouse look, rather than reacting to report arrival: the
    // camera then moves at a constant speed even if the receiver coalesces or drops
    // reports while the stick is held still.
    let interval = 1.0 / config.pollRateHz
    session.timer = CFRunLoopTimerCreateWithHandler(
        kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + interval, interval, 0, 0
    ) { _ in
        session.engine?.tick()
    }
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), session.timer, .defaultMode)

case "monitor":
    note("Watching controller. Press Ctrl-C to stop.\n")

case "calibrate":
    note("")

default:
    break
}

// Warn if nothing showed up, instead of hanging with no output at all.
let watchdog = CFRunLoopTimerCreateWithHandler(
    kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 3.0, 0, 0, 0
) { _ in
    guard !session.sawDevice else { return }
    print("""
        ⚠️  No controller found after 3s.
           - Is the USB receiver plugged in and the pad powered on (LED lit)?
           - Press the pad's ANALOG button so the receiver pairs.
           - Looking for VID 0x\(String(format: "%04x", config.vendorID)) \
        PID 0x\(String(format: "%04x", config.productID)).
           - Check it is visible:  ioreg -c IOHIDDevice -r -l | grep -i gamepad
        """)
    fflush(stdout)
}
CFRunLoopAddTimer(CFRunLoopGetCurrent(), watchdog, .defaultMode)

CFRunLoopRun()
