import CoreGraphics
import Foundation

/// A dependency-free check of the pure logic: report decoding, the binding grammar, the
/// look curve, and config loading.
///
/// This lives in the shipping binary rather than a SwiftPM test target on purpose. The
/// Command Line Tools install that builds this package has no usable XCTest or
/// swift-testing module, and a check the user can run against their own build
/// (`ps2mc selftest`) is more useful here than one only CI can run.
public enum SelfTest {
    private static var failures: [String] = []
    private static var checks = 0

    private static func expect(_ condition: Bool, _ description: String,
                               file: String = #fileID, line: Int = #line) {
        checks += 1
        if !condition { failures.append("\(description)  (\(file):\(line))") }
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ what: String,
                                                  file: String = #fileID, line: Int = #line) {
        checks += 1
        if actual != expected {
            failures.append("\(what): expected \(expected), got \(actual)  (\(file):\(line))")
        }
    }

    private static func expectClose(_ actual: Double, _ expected: Double, _ what: String,
                                    tolerance: Double = 0.01,
                                    file: String = #fileID, line: Int = #line) {
        checks += 1
        if abs(actual - expected) > tolerance {
            failures.append("\(what): expected ≈\(expected), got \(actual)  (\(file):\(line))")
        }
    }

    private static func expectThrows(_ what: String, _ body: () throws -> Void,
                                     file: String = #fileID, line: Int = #line) {
        checks += 1
        do {
            try body()
            failures.append("\(what): expected an error, none thrown  (\(file):\(line))")
        } catch {}
    }

    /// A representative 27-byte report from the 2563:0575 receiver.
    private static func report(buttons: UInt16 = 0, hat: UInt8 = 0x0F,
                               lx: UInt8 = 128, ly: UInt8 = 128,
                               rx: UInt8 = 128, ry: UInt8 = 128) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: ControllerState.reportLength)
        bytes[0] = UInt8(buttons & 0xFF)
        bytes[1] = UInt8((buttons >> 8) & 0xFF)
        bytes[2] = hat
        bytes[3] = lx; bytes[4] = ly; bytes[5] = rx; bytes[6] = ry
        return bytes
    }

    public static func run() -> Int32 {
        let order = ButtonID.defaultBitOrder

        // MARK: Report decoding
        if let state = ControllerState.decode(report: report(), bitOrder: order) {
            // 128 is one step past the 127/128 midpoint, so a tiny bias is expected; what
            // matters is that it lands well inside every sane deadzone.
            expectClose(state.leftX, 0, "centred left X")
            expectClose(state.rightY, 0, "centred right Y")
            expect(state.buttons.isEmpty, "no buttons on an idle report")
            expect(state.dpad.isEmpty, "centred hat yields no direction")
        } else {
            failures.append("a full-length report failed to decode")
        }

        if let state = ControllerState.decode(
            report: report(lx: 0, ly: 0, rx: 255, ry: 255), bitOrder: order) {
            expectClose(state.leftX, -1, "left X at minimum")
            expectClose(state.rightX, 1, "right X at maximum")
        }

        if let state = ControllerState.decode(report: report(buttons: 0b1000001), bitOrder: order) {
            expectEqual(state.buttons, [order[0], order[6]], "bits map through the configured order")
        }
        if let state = ControllerState.decode(report: report(buttons: 0xE000), bitOrder: order) {
            expect(state.buttons.isEmpty, "padding bits above 13 are ignored")
        }

        let hatCases: [(UInt8, Set<DPadID>)] = [
            (0, [.up]), (1, [.up, .right]), (2, [.right]), (3, [.down, .right]),
            (4, [.down]), (5, [.down, .left]), (6, [.left]), (7, [.up, .left]),
            (8, []), (15, []),
        ]
        for (hat, expected) in hatCases {
            let decoded = ControllerState.decode(report: report(hat: hat), bitOrder: order)?.dpad
            expectEqual(decoded ?? [], expected, "hat value \(hat)")
        }
        expect(ControllerState.decode(report: [0, 0, 0], bitOrder: order) == nil,
               "a short report is rejected rather than read out of bounds")

        // MARK: Action grammar
        do {
            if case .key(let code, _, let flags, let mode) = try Action.parse("key:w") {
                expectEqual(code, 0x0D, "key:w keycode")
                expectEqual(flags, [], "key:w carries no modifiers")
                expectEqual(mode, .hold, "a bare key defaults to hold")
            } else { failures.append("key:w did not parse as a key") }

            if case .key(_, _, _, let mode) = try Action.parse("key:shift@toggle") {
                expectEqual(mode, .toggle, "the @mode suffix is honoured")
            } else { failures.append("key:shift@toggle did not parse as a key") }

            if case .key(let code, _, let flags, _) = try Action.parse("combo:shift+ctrl+w") {
                expectEqual(code, 0x0D, "combo resolves the final key")
                expect(flags.contains(.maskShift), "combo raises shift")
                expect(flags.contains(.maskControl), "combo raises control")
            } else { failures.append("combo:shift+ctrl+w did not parse as a key") }

            expectEqual(try Action.parse("mouse:left"), .mouse(.left, mode: .hold), "mouse:left")
            expectEqual(try Action.parse("scroll:up*3"), .scroll(.up, amount: 3), "scroll:up*3")
            expectEqual(try Action.parse("hotbar:next"), .hotbarNext, "hotbar:next")
            expectEqual(try Action.parse("hotbar:prev"), .hotbarPrev, "hotbar:prev")
            expectEqual(try Action.parse("hotbar:4"), .hotbarSlot(4), "hotbar:4")
            expectEqual(try Action.parse("special:toggleEngine"), .toggleEngine, "special:toggleEngine")
            expectEqual(try Action.parse("none"), Action.none, "none")
            expectEqual(try Action.parse(""), Action.none, "an empty binding")
        } catch {
            failures.append("a valid binding threw: \(error.localizedDescription)")
        }

        for bad in ["key:nosuchkey", "nonsense:w", "key:w@sideways", "bareword", "hotbar:99"] {
            expectThrows("\"\(bad)\" should be rejected") { _ = try Action.parse(bad) }
        }

        // MARK: Look curve
        let look = LookBinding.minecraftDefault
        // Derive the probe from the configured deadzone so retuning cannot rot the test.
        let wellInside = look.deadzone * 0.5
        let inside = Engine.shape(x: wellInside * 0.9, y: wellInside * 0.4, look: look)
        expect(inside.0 == 0 && inside.1 == 0, "inside the deadzone produces no motion")
        expectClose(Engine.shape(x: 1.0, y: 0, look: look).0, 1.0,
                    "full deflection reaches full scale", tolerance: 0.001)
        // Each axis alone sits inside the 0.14 deadzone, but together they clear it.
        let diagonal = Engine.shape(x: 0.12, y: 0.12, look: look)
        expect(abs(diagonal.0) > 0, "the deadzone is radial, so diagonals survive")
        expectClose(diagonal.0, diagonal.1, "a 45° push stays on the diagonal", tolerance: 0.0001)
        let near = Engine.shape(x: 0.3, y: 0, look: look).0
        let mid = Engine.shape(x: 0.6, y: 0, look: look).0
        let far = Engine.shape(x: 0.9, y: 0, look: look).0
        expect(near < mid && mid < far, "the response curve is monotonic")
        expect(mid < 0.6, "an exponent above 1 eases response near centre")

        // MARK: Motion smoothness
        // A gentle push must still move the camera. Before sub-pixel accumulation this
        // rounded to zero every tick, leaving fine aim completely dead below about a third
        // of stick travel — the single biggest source of choppy camera movement.
        let dt = 1.0 / Config().pollRateHz
        let ticksPerSecond = Int(Config().pollRateHz)
        var residual = 0.0
        var pixelsMoved = 0.0
        var ticksThatMoved = 0
        // A deliberate, slow pan just past the deadzone — the kind fine aiming is made of,
        // and slow enough that a single tick moves well under one pixel.
        let gentleDeflection = look.deadzone + (1 - look.deadzone) * 0.06
        let gentle = Engine.shape(x: gentleDeflection, y: 0, look: look).0
        expect(gentle * look.sensitivityX * dt < 0.5,
               "the probe is slow enough that one tick alone rounds to nothing")
        for _ in 0..<ticksPerSecond {
            let raw = gentle * look.sensitivityX * dt + residual
            let step = raw.rounded(.towardZero)
            residual = raw - step
            pixelsMoved += step
            if step != 0 { ticksThatMoved += 1 }
        }
        expect(pixelsMoved > 0, "a gentle push must still move the camera")
        expectClose(pixelsMoved, gentle * look.sensitivityX, "a second of travel lands on target",
                    tolerance: 1.5)
        expect(ticksThatMoved > 1, "motion is spread across ticks rather than one jump")
        expect(ticksThatMoved < ticksPerSecond,
               "a slow pan does not move on every tick — that is what the remainder is for")
        // Without the carried remainder this same push produces nothing at all.
        let naive = (gentle * look.sensitivityX * dt).rounded()
        expectEqual(naive, 0, "the naive per-tick rounding this replaced floored to zero")

        // Smoothing must be frame-rate independent: the same elapsed time has to produce
        // the same result whether it arrives as few big ticks or many small ones.
        func settle(tau: Double, dt: Double, steps: Int) -> Double {
            var value = 0.0
            for _ in 0..<steps { value += (1.0 - value) * (1 - exp(-dt / tau)) }
            return value
        }
        let coarse = settle(tau: 0.035, dt: 1.0 / 60, steps: 60)
        let fine = settle(tau: 0.035, dt: 1.0 / 250, steps: 250)
        expectClose(coarse, fine, "smoothing does not change with poll rate", tolerance: 0.001)
        expect(settle(tau: 0.035, dt: dt, steps: 1) < 0.3, "one tick only eases part-way")

        // MARK: Look throughput
        // The window server truncates mouse deltas to whole pixels, so a pan of N px/s
        // arrives as N discrete steps per second. Smoothness at low speed is therefore a
        // function of how many pixels the driver moves, not how clean its arithmetic is.
        // These bounds guard the two ends: a slow pan must clear the rate at which
        // individual steps read as stutter, and a full push must turn at a usable speed.
        let slowPan = Engine.shape(x: 0.25, y: 0, look: look).0 * look.sensitivityX
        expect(slowPan > 100,
               "a slow pan clears ~100 steps/s, above the point where steps read as stutter")
        let fullPush = Engine.shape(x: 1.0, y: 0, look: look).0 * look.sensitivityX
        expectClose(fullPush, look.sensitivityX, "full deflection reaches full sensitivity",
                    tolerance: 0.5)
        // Minecraft needs roughly 2400 px of travel for a 360° turn at default in-game
        // sensitivity. Under about half a turn per second the camera feels sluggish, and
        // sluggish is exactly the regime where pixel stepping becomes visible.
        let turnsPerSecond = fullPush / 2400
        expect(turnsPerSecond > 0.8, "a full push turns at a usable speed")
        expect(turnsPerSecond < 3.0, "a full push is not so fast as to be uncontrollable")

        // MARK: Directional engagement
        // Engagement is radial, so every direction starts at the same distance. The old
        // per-axis test made a diagonal need 1.41x the travel of a cardinal.
        let move = MoveBinding.minecraftDefault
        func engages(x: Double, y: Double) -> Bool {
            (x * x + y * y).squareRoot() >= move.threshold
        }
        // Compare a cardinal and a diagonal push at the same radial distance, just past
        // the threshold. Testing exactly *at* it only measures floating-point luck.
        let root2: Double = 2.0.squareRoot()
        let justPast: Double = move.threshold + 0.01
        let justShort: Double = move.threshold - 0.01
        expect(engages(x: 0, y: -justPast), "a cardinal push past the threshold engages")
        expect(engages(x: justPast / root2, y: -justPast / root2),
               "a diagonal push at the same distance engages too")
        expect(!engages(x: 0, y: -justShort), "a cardinal push short of the threshold does not")
        expect(!engages(x: justShort / root2, y: -justShort / root2),
               "a diagonal push short of the threshold does not either")
        // The regression this guards: each axis of that diagonal sits well below the
        // threshold, so the old per-axis test would have refused to move at all.
        expect(justPast / root2 < move.threshold,
               "per-axis testing would have missed an engaging diagonal")

        // The default tolerance must split the circle into eight even sectors.
        expectClose(move.directionTolerance, sin(22.5 * .pi / 180),
                    "the direction tolerance is sin(22.5°)", tolerance: 0.005)
        expect(move.directionTolerance < root2 / 2,
               "a diagonal's components clear the tolerance, so diagonals are reachable")

        // MARK: Configuration
        do {
            let resolved = try Config().resolveBindings()
            expectEqual(resolved.buttons[.l2], .mouse(.left, mode: .hold), "L2 destroys")
            expectEqual(resolved.buttons[.r2], .mouse(.right, mode: .hold), "R2 places")
            expectEqual(resolved.buttons[.l1], .hotbarPrev, "L1 steps the hotbar back")
            expectEqual(resolved.buttons[.r1], .hotbarNext, "R1 steps the hotbar forward")
            expectEqual(resolved.buttons[.analog], .toggleEngine, "Analog mutes output")
        } catch {
            failures.append("the shipped defaults do not resolve: \(error.localizedDescription)")
        }

        let defaults = Config()
        expectEqual(defaults.leftStick.role, .move, "the left stick drives movement")
        expectEqual(defaults.rightStick.role, .look, "the right stick drives the camera")
        expectEqual(defaults.leftStick.move.up, "key:w", "forward is W")
        expectEqual(defaults.leftStick.move.down, "key:s", "back is S")
        expectEqual(defaults.leftStick.move.left, "key:a", "left is A")
        expectEqual(defaults.leftStick.move.right, "key:d", "right is D")

        do {
            // These inputs are deliberately broken, so mute the repair warnings they
            // would otherwise print — here they are the expected behaviour, not a fault.
            let decoder = JSONDecoder()
            decoder.userInfo[.suppressWarnings] = true

            let sparse = #"{"buttons":{"a":"key:space"},"pollRateHz":9999}"#
            let config = try decoder.decode(Config.self, from: Data(sparse.utf8))
            expectEqual(config.vendorID, 0x2563, "a sparse config keeps the default vendor ID")
            expectEqual(config.leftStick.role, .move, "a sparse config keeps stick roles")
            expectEqual(config.leftStick.move.directionTolerance,
                        MoveBinding.minecraftDefault.directionTolerance,
                        "a sparse config keeps the new tuning defaults")

            // Values that would silently disable a stick are clamped, not honoured.
            let absurd = #"{"rightStick":{"role":"look","look":{"deadzone":5,"smoothingMs":-3}},"leftStick":{"role":"move","move":{"threshold":9,"directionTolerance":0.99}}}"#
            let tamed = try decoder.decode(Config.self, from: Data(absurd.utf8))
            expect(tamed.rightStick.look.deadzone <= 0.9, "an absurd deadzone is clamped")
            expect(tamed.rightStick.look.smoothingMs >= 0, "negative smoothing is clamped")
            expect(tamed.leftStick.move.threshold <= 0.95, "an absurd threshold is clamped")
            expect(tamed.leftStick.move.directionTolerance <= 0.70,
                   "a tolerance that would kill diagonals is clamped")
            expect(tamed.leftStick.move.releaseHysteresis < tamed.leftStick.move.threshold,
                   "hysteresis stays below the threshold it backs off from")
            expectEqual(config.buttonBitOrder.count, 13, "a sparse config keeps a full bit order")
            expectEqual(config.pollRateHz, 500, "an absurd poll rate is clamped")

            let broken = #"{"buttonBitOrder":["a","a"]}"#
            let repaired = try decoder.decode(Config.self, from: Data(broken.utf8))
            expectEqual(repaired.buttonBitOrder, ButtonID.defaultBitOrder,
                        "a malformed bit order is replaced")
        } catch {
            failures.append("decoding a partial config threw: \(error.localizedDescription)")
        }

        // A config written with PlayStation shape names must still resolve, mapping by
        // position onto the letter-labelled buttons this pad actually has.
        expectEqual(ButtonID.named("triangle"), .y, "triangle is the top button, Y")
        expectEqual(ButtonID.named("circle"), .b, "circle is the right button, B")
        expectEqual(ButtonID.named("cross"), .a, "cross is the bottom button, A")
        expectEqual(ButtonID.named("square"), .x, "square is the left button, X")
        expectEqual(ButtonID.named("A"), .a, "button names are case-insensitive")
        expect(ButtonID.named("nonsense") == nil, "an unknown button name is rejected")
        // "x" must stay the letter, not the PlayStation reading of Cross.
        expectEqual(ButtonID.named("x"), .x, "x is the left button, not cross")

        do {
            let legacy = #"{"buttonBitOrder":["triangle","circle","cross","square","l1","r1","l2","r2","select","start","l3","r3","analog"],"buttons":{"cross":"key:space"}}"#
            let config = try JSONDecoder().decode(Config.self, from: Data(legacy.utf8))
            expectEqual(config.buttonBitOrder, ButtonID.defaultBitOrder,
                        "a shape-named bit order decodes to the same physical order")
            let resolved = try config.resolveBindings()
            expectEqual(resolved.buttons[.a], .key(0x31, name: "space", flags: [], mode: .hold),
                        "a shape-named binding lands on the right button")
        } catch {
            failures.append("a shape-named config failed to load: \(error.localizedDescription)")
        }

        var broken = Config()
        broken.buttons["a"] = "key:bogus"
        broken.dpad["up"] = "alsobogus"
        do {
            _ = try broken.resolveBindings()
            failures.append("two bad bindings should have thrown")
            checks += 1
        } catch {
            let text = error.localizedDescription
            expect(text.contains("buttons.a") && text.contains("dpad.up"),
                   "every bad binding is reported at once, not just the first")
        }

        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ps2mc-selftest-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            var config = Config()
            config.buttons["a"] = "key:f@tap"
            try config.save(to: url)
            expectEqual(try Config.load(from: url).buttons["a"], "key:f@tap",
                        "config round-trips through disk")
        } catch {
            failures.append("config round-trip threw: \(error.localizedDescription)")
        }

        // MARK: Hotbar wrapping
        expectEqual((0 - 1) %% 9, 8, "stepping below slot 1 wraps to 9")
        expectEqual((8 + 1) %% 9, 0, "stepping past slot 9 wraps to 1")
        expectEqual(3 %% 9, 3, "a mid-range step is unchanged")

        // MARK: Report
        if failures.isEmpty {
            print("✅ \(checks) checks passed")
            return 0
        }
        print("❌ \(failures.count) of \(checks) checks failed\n")
        for failure in failures { print("  • \(failure)") }
        return 1
    }
}
