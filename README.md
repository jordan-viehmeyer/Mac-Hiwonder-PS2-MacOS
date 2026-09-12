# ps2mc — HiWonder PS2 Wireless Controller driver for macOS

A userspace driver that turns the [HiWonder PS2 wireless
controller](https://www.hiwonder.com/products/ps2-wireless-handle-with-usb-receiver)
(the pad that ships with HiWonder's ROS robot kits) into keyboard and mouse input on
**macOS 26.1+**, tuned out of the box for **Minecraft**.

No kernel extension, no DriverKit bundle, no reboot. It reads the receiver through IOKit's
HID manager and posts synthetic events with CoreGraphics, so it works with any app that
takes keyboard and mouse input — Minecraft is just what the defaults are shaped for.

Ships as **PS2MC.app** — a SwiftUI app with a menu bar item, live controller view, visual
binding editor and guided calibration — and as **`ps2mc`**, the same engine as a CLI. Both
frontends share one library and one config file.

- Built and tested on macOS 26.1 (build 25B78), Apple silicon, Swift 6.2.
- Hardware: `USB WirelessGamepad`, USB `2563:0575`.

---

## Contents

- [Install](#install)
- [The app](#the-app)
- [First run](#first-run)
- [Default Minecraft mapping](#default-minecraft-mapping)
- [Commands](#commands)
- [Customising the mapping](#customising-the-mapping)
  - [Binding grammar](#binding-grammar)
  - [Key names](#key-names)
  - [Sticks](#sticks)
  - [Full config reference](#full-config-reference)
- [Run at login](#run-at-login)
- [Troubleshooting](#troubleshooting)
- [How it works](#how-it-works)
- [Using it for ROS instead](#using-it-for-ros-instead)

---

## Install

Requires the Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not needed —
the `.app` bundle is assembled by script rather than by `xcodebuild`.

### The app

```sh
git clone <this repo> Mac-Hiwonder-PS2-MacOS
cd Mac-Hiwonder-PS2-MacOS
./scripts/build-app.sh
cp -R build/PS2MC.app /Applications/
open /Applications/PS2MC.app
```

**Keep it in `/Applications`.** macOS ties Input Monitoring and Accessibility to the app's
path *and* its code signature, so moving the bundle later means granting both again. The
build script ad-hoc signs it so that identity at least stays stable across rebuilds.

### The command line tool

```sh
./scripts/install.sh          # builds, self-tests, installs to /usr/local/bin/ps2mc
```

`PREFIX=~/.local ./scripts/install.sh` installs elsewhere. The same binary also ships
inside the app at `PS2MC.app/Contents/Resources/ps2mc`, so the two are always the same
build. To work in the tree without installing:

```sh
swift build -c release
.build/release/ps2mc --help
```

## The app

| Tab | What is there |
|---|---|
| **Status** | Permission state with request buttons, live stick and button view, calibration |
| **Bindings** | Every button and D-pad direction, with a preset menu and a free-text field |
| **Tuning** | Stick roles, sensitivity, deadzone, curve, smoothing, movement thresholds |

The **menu bar item** is the part that matters in a full-screen game, where the window is
unreachable: it shows connection state and offers Start/Stop and **Mute Output** without
leaving the game. The pad's Analog button does the same thing, and the two stay in sync.

Edits validate as you type — a binding that will not parse is reported in the footer with
the field that caused it, and Save stays disabled until it is fixed. Saving writes the same
`~/.config/ps2mc/config.json` the CLI uses and restarts the driver so changes take effect.

The live controller view is the fastest way to answer the two questions that come up most:
is the pad reaching the Mac at all, and is the button order calibrated correctly. The stick
display draws the deadzone, so a worn stick resting outside it — the usual cause of phantom
camera drift — is visible rather than guessed at.

Calibration stops the driver first, so pressing every button in turn cannot leak keystrokes
into whatever is behind the window.

---

## First run

```sh
ps2mc permissions   # 1. grant the two macOS permissions
ps2mc calibrate     # 2. teach it your pad's button order
ps2mc monitor       # 3. confirm everything reads correctly
ps2mc run           # 4. play
```

### 1. Permissions

The app shows both on its Status tab with buttons to request them or jump straight to the
right System Settings pane. From the CLI, `ps2mc permissions` does the same.

Two separate, independently revocable grants are needed:

| Permission | Why | Symptom if missing |
|---|---|---|
| **Input Monitoring** | read the gamepad | controller looks permanently idle |
| **Accessibility** | post keys and mouse | sticks read fine, nothing reaches the game |

Grant them to whatever *launches* the driver. For the app that is **PS2MC.app** itself; for
the CLI run from a terminal it is **Terminal** or **iTerm**, not `ps2mc`. This is the main
practical reason to prefer the app: the bundle is a stable, signed identity, whereas a
terminal's grant covers anything you run from it.

System Settings → Privacy & Security → **Input Monitoring** / **Accessibility**.

### 2. Calibrate

In the app: **Status → Calibrate buttons…**. From the CLI:

PS2-to-USB adapter clones disagree about which of the 13 button bits belongs to which
button — in particular whether the shoulder block runs `L1,R1,L2,R2` or `L2,R2,L1,R1`.
Getting it wrong silently swaps "destroy block" with "change hotbar slot".

`ps2mc calibrate` names each button, waits for you to press it, and writes the real order
to your config. It prompts with the letters printed on the pad — **Y (top)**, **A
(bottom)**, **X (left)**, **B (right)** — so press whatever the label says and the mapping
follows your hardware, whichever lettering it uses. Press Return to skip a button your pad
does not have; Ctrl-C aborts without touching the config.

Do this once. The shipped default order is the common case, so if `ps2mc monitor` already
names buttons correctly you can skip it.

### 3. Verify

`ps2mc monitor` draws live stick positions and button names. Use it to confirm the
calibration, spot stick drift, and check the pad is paired at all. Add `--raw` to see the
underlying report bytes.

---

## Default Minecraft mapping

The mapping the brief called for, plus sensible defaults for everything else.

### Sticks

| Stick | Role | Detail |
|---|---|---|
| **Left** | Movement | forward `W`, back `S`, left `A`, right `D` — diagonals work |
| **Right** | Camera / look | 360° mouse look, radial deadzone, eased and smoothed |

This is the console-Minecraft convention. To swap them, see [Sticks](#sticks).

### Triggers and bumpers

| Button | Action | Minecraft |
|---|---|---|
| **L2** (lower-left) | Left click | Attack / **destroy** |
| **R2** (lower-right) | Right click | Use / **place** |
| **L1** (upper-left) | Hotbar previous | one slot left |
| **R1** (upper-right) | Hotbar next | one slot right |

### Face buttons

The HiWonder pad is labelled **Y / A / X / B** (Xbox-style lettering), not PlayStation
shapes. Positions are the usual ones: Y top, A bottom, X left, B right.

| Button | Binding | Minecraft |
|---|---|---|
| **A** (bottom) | `key:space` | Jump |
| **B** (right) | `key:shift@toggle` | Sneak — latched, so no held thumb on long descents |
| **Y** (top) | `key:e` | Inventory |
| **X** (left) | `key:q@repeat` | Drop item; hold to empty a stack |

> **Shape names still work.** `triangle`, `circle`, `cross` and `square` are accepted
> anywhere a button name is read, and map by position: △→Y, ○→B, ✕→A, □→X. A config
> written for a shape-labelled pad loads unchanged.
>
> One deliberate exception: plain `x` always means the **X button (left)**, never Cross.
> If your pad has shapes and you mean Cross, write `cross`.

### Sticks clicked, system buttons, D-pad

| Button | Binding | Minecraft |
|---|---|---|
| L3 (left stick click) | `key:f` | Swap item to off-hand |
| R3 (right stick click) | `key:control@toggle` | Sprint — latched |
| Select | `key:tab` | Player list |
| Start | `key:escape` | Pause / release mouse grab |
| **Analog / Mode** | `special:toggleEngine` | **Mute all output** — the panic button |
| D-pad ↑ | `key:t` | Chat |
| D-pad ↓ | `key:f5` | Cycle camera perspective |
| D-pad ← | `hotbar:1` | First hotbar slot |
| D-pad → | `hotbar:9` | Last hotbar slot |

> **The Analog button is your escape hatch.** Press it to suspend the driver — every held
> key and mouse button is released and the sticks stop moving the cursor — so you can
> alt-tab, type, or walk away without the pad fighting you. Press it again to resume.
> Ctrl-C also releases everything cleanly.

---

## Commands

| Command | What it does |
|---|---|
| `ps2mc run` | Start the driver. The default if no command is given. |
| `ps2mc monitor` | Live view of decoded controller state. `--raw` adds report bytes. |
| `ps2mc calibrate` | Learn the pad's button bit order and save it. |
| `ps2mc permissions` | Check and request the two required macOS permissions. |
| `ps2mc config` | Print the active config. `--path` prints just its location. |
| `ps2mc keys` | List every key name accepted in a binding. |
| `ps2mc selftest` | Verify decoding, the binding grammar, the look curve and config handling. |
| `ps2mc version` | Print the version. |

Global options: `--config <path>` to use an alternate config file, `--quiet` to suppress
the banner and event log, `--help`.

---

## Customising the mapping

Config lives at `~/.config/ps2mc/config.json`, written with defaults on first run. Edit it
with any text editor and restart `ps2mc run`.

It is meant to be edited by hand, so **every field is optional** — delete anything you do
not care about and the default is used. A typo is reported with the offending line rather
than silently ignored, and *all* bad bindings are listed at once:

```
ps2mc: invalid bindings in /Users/you/.config/ps2mc/config.json:
  - buttons.a: unknown key name 'spcae' in "key:spcae" — run `ps2mc keys` for the full list
  - dpad.up: could not parse action "chat"
```

### Binding grammar

Every binding is one string: `<kind>:<value>[@<mode>]`

| Form | Meaning |
|---|---|
| `key:w` | Hold `W` while the button is held |
| `key:space@tap` | One press-and-release per button press |
| `key:shift@toggle` | Latch on; stays down until the next press |
| `key:q@repeat` | Press, then auto-repeat while held |
| `combo:shift+w` | Hold `Shift`+`W` together |
| `mouse:left` | Hold left click (also `right`, `middle`) |
| `scroll:up` | One wheel notch up (also `down`, `left`, `right`) |
| `scroll:up*3` | Three notches at once |
| `hotbar:next` | Advance one hotbar slot |
| `hotbar:prev` | Go back one hotbar slot |
| `hotbar:5` | Jump to hotbar slot 5 (`1`–`9`) |
| `special:toggleEngine` | Suspend / resume all output |
| `none` | Explicitly unbound |

**Modes**

| Mode | Behaviour |
|---|---|
| `hold` *(default)* | Press on button-down, release on button-up. What movement keys want. |
| `tap` | One press-and-release per button-down, however long you hold it. |
| `toggle` | Each press flips a latch. Good for sneak and sprint. |
| `repeat` | Press immediately, then repeat every `repeatIntervalMs` after `repeatDelayMs`. |

**Bindable inputs:** `y`, `b`, `a`, `x`, `l1`, `r1`, `l2`, `r2`, `select`, `start`, `l3`,
`r3`, `analog` under `buttons`; `up`, `down`, `left`, `right` under `dpad`. The shape
aliases `triangle`, `circle`, `cross` and `square` are accepted too.

Example — swap sneak to hold-style and put the inventory on Select:

```json
{
  "buttons": {
    "b": "key:shift",
    "select": "key:e",
    "y": "combo:shift+f3"
  }
}
```

### Key names

Run `ps2mc keys` for the full list. Letters and digits are themselves (`a`, `7`); the rest
are spelled out: `space`, `return`, `tab`, `escape`, `delete`, `shift`, `control`, `option`,
`command`, `up`/`down`/`left`/`right`, `f1`–`f20`, `keypad0`–`keypad9`, `comma`, `period`,
`slash`, `semicolon`, `quote`, `grave`, `minus`, `equal`, `leftbracket`, `rightbracket`,
`backslash`.

Key names map to **physical key positions** on a US/ANSI layout, which is what Minecraft
(via GLFW) reads. `key:w` stays on the same physical key whatever your input source is.

> Avoid binding `f3` alone on a Mac — macOS claims it for Mission Control. Minecraft's
> debug screen is reachable as `combo:fn+f3` depending on your keyboard settings.

### Sticks

Each stick has a `role`:

| Role | Effect |
|---|---|
| `look` | Drives the mouse — camera control |
| `move` | Drives four directional keys |
| `none` | Ignored |

**To swap the sticks** (camera on the left, movement on the right), swap the two `role`
values:

```json
{
  "leftStick":  { "role": "look" },
  "rightStick": { "role": "move" }
}
```

**Look tuning** (`rightStick.look` by default):

| Field | Default | Meaning |
|---|---|---|
| `sensitivityX` | `2800` | Pixels of mouse travel per second at full deflection |
| `sensitivityY` | `2000` | Same, vertically — lower than X on purpose, as in most shooters |
| `deadzone` | `0.10` | Radial deadzone, 0–1. Raise it if the camera drifts at rest |
| `exponent` | `1.5` | Response curve. `1.0` is linear; higher gives finer aim near centre |
| `smoothingMs` | `28` | Smoothing time constant. Higher is smoother but less immediate; `0` disables |
| `invertY` | `false` | Flight-sim style inverted vertical look |
| `invertX` | `false` | Invert horizontal look |

Camera too slow? Raise `sensitivityX`/`sensitivityY`. Twitchy at small movements? Raise
`exponent`. Drifting when you let go? Raise `deadzone`. Feels laggy? Lower `smoothingMs`
toward `0`.

**If the camera feels steppy, raise sensitivity — do not lower it.** macOS truncates
synthetic mouse deltas to whole pixels, so a pan of *N* px/s reaches the game as *N*
discrete one-pixel steps per second. Moving more pixels means finer steps, not coarser
ones. Lowering sensitivity to "calm it down" makes stepping worse. If that leaves the
camera turning faster than you like, raise `sensitivityX`/`sensitivityY` further **and**
lower Minecraft's own sensitivity slider by the same proportion: the angular speed stays
put while the motion gets smoother. This is the same trick as running a high-DPI mouse at
low in-game sensitivity.

**Move tuning** (`leftStick.move` by default):

| Field | Default | Meaning |
|---|---|---|
| `up` / `down` / `left` / `right` | `key:w` / `key:s` / `key:a` / `key:d` | Bindings, same grammar as buttons |
| `threshold` | `0.30` | How far the stick must travel before movement engages, measured radially |
| `releaseHysteresis` | `0.08` | Extra travel needed to release, so a stick resting near the threshold does not machine-gun the key |
| `directionTolerance` | `0.38` | How much of the push must point along an axis for that direction to count. `0.38` is sin(22.5°), giving eight equal 45° sectors. Lower widens diagonals; higher widens cardinals |
| `releaseDelayMs` | `40` | Grace period before a direction is actually released, smoothing the dip you get rotating between sectors. `0` disables |

Movement engaging too late? Lower `threshold`. Diagonals hard to hold? Lower
`directionTolerance`. Direction flickering while you rotate the stick? Raise
`releaseDelayMs`.

### Full config reference

| Field | Default | Meaning |
|---|---|---|
| `vendorID` | `9571` (`0x2563`) | USB vendor ID to match |
| `productID` | `1397` (`0x0575`) | USB product ID to match |
| `matchAnyGamepad` | `true` | Also accept any HID gamepad/joystick, for other adapter clones |
| `buttonBitOrder` | `y b a x l1 r1 l2 r2 select start l3 r3 analog` | Which button each report bit is. Written by `calibrate` |
| `pollRateHz` | `250` | How often stick state becomes mouse motion. Clamped to 30–500. Above the receiver's own 125 Hz on purpose — smoothing interpolates between reports, so extra ticks space the motion more evenly |
| `hotbarMode` | `"scroll"` | `scroll` posts a wheel notch; `numbers` tracks the slot and presses `1`–`9` |
| `repeatIntervalMs` | `120` | Gap between `@repeat` fires |
| `repeatDelayMs` | `350` | Delay before `@repeat` starts repeating |

`hotbarMode: "scroll"` is the default because the *game* owns the slot index, so it can
never drift out of sync with what you see. `"numbers"` is deterministic but desyncs if you
also scroll the wheel or click a slot directly.

---

## Run at login

Optional — a LaunchAgent is included.

```sh
cp scripts/family.theviehmeyers.ps2mc.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/family.theviehmeyers.ps2mc.plist
```

Unload with `launchctl unload ~/Library/LaunchAgents/family.theviehmeyers.ps2mc.plist`.
Logs go to `/tmp/ps2mc.log` and `/tmp/ps2mc.err.log`.

Under launchd, ps2mc is its own process, so the two permissions must be granted to
`/usr/local/bin/ps2mc` itself rather than to your terminal.

> Consider whether you want this. A driver running at login is posting keystrokes whenever
> the pad is touched, in whatever app happens to be focused. Starting it by hand when you
> sit down to play is the safer habit — and the Analog button mutes it either way.

---

## Troubleshooting

**The app shows "Permissions needed" after you granted them** — macOS keys the grant to
the bundle's path and signature. If you rebuilt or moved the app, remove the stale entry in
System Settings (select it, press −) and add the new one, or run
`tccutil reset Accessibility family.theviehmeyers.ps2mc`.

**"No controller found after 3s."**

- Is the USB receiver plugged in and the pad powered on (LED lit)?
- Press the pad's **Analog** button so the receiver pairs — an unpaired pad enumerates but
  sends nothing.
- Confirm macOS sees the hardware:
  ```sh
  ioreg -c IOHIDDevice -r -l | grep -i "USB Product Name"
  ```
  You are looking for `USB WirelessGamepad`.
- A different adapter clone? Put its IDs in `vendorID` / `productID`, or leave
  `matchAnyGamepad: true` and it will be picked up as a generic gamepad.

**Buttons do the wrong thing** — run `ps2mc calibrate`. This is the expected fix; adapter
clones vary.

**The controller reads fine in `monitor` but nothing happens in the game** — that is
Accessibility, not Input Monitoring. Run `ps2mc permissions`.

**Permission toggle is already on but nothing works** — macOS caches grants per binary path,
and a stale entry survives a rebuild. Toggle it off and on, or reset:

```sh
tccutil reset Accessibility
tccutil reset ListenEvent
```

Then re-grant. If you moved or reinstalled the binary, re-grant for the new path.

**Camera drifts on its own** — worn sticks rest off-centre. Check the resting values in
`ps2mc monitor` and raise `deadzone` past the drift.

**Movement keys stutter** — raise `releaseDelayMs`, then `releaseHysteresis`. Raise
`threshold` if it triggers too eagerly.

**Camera feels steppy or dead at small pushes** — raise `sensitivityX`/`sensitivityY`, and
lower Minecraft's own sensitivity to compensate if the result turns too fast. Lowering
ps2mc's sensitivity makes stepping worse, not better; see
[Sticks](#sticks). Lowering `deadzone` and `exponent` also helps.

**Camera feels laggy** — lower `smoothingMs` toward `0`.

**A key got stuck down** — press the Analog button twice, or Ctrl-C. Both release
everything held. If a crash ever leaves something latched, tapping the physical key clears it.

**Minecraft ignores the camera but the cursor moves** — the mouse events are being posted
but not as deltas. That should not happen (see below), but confirm Minecraft has focus and
the cursor is grabbed (you are in-world, not in a menu).

---

## How it works

```
USB receiver ──HID──▶ IOHIDManager ──27-byte report──▶ decode ──▶ Engine ──CGEvent──▶ macOS ──▶ Minecraft
                                                                    ▲
                                                         125 Hz tick drives mouse look
```

**Reading.** The adapter exposes one 27-byte input report with no report ID, so ps2mc
subscribes to the whole report rather than registering a callback per HID element:

| Bytes | Contents |
|---|---|
| `0–1` | 13 button bits, LSB first (bits 13–15 are padding) |
| `2` | D-pad hat in the low nibble: `0`=N, `2`=E, `4`=S, `6`=W, `8`/`15`=centre |
| `3–6` | `X`, `Y`, `Z`, `Rz` — left stick X/Y then right stick X/Y, each `0–255` |
| `7–26` | Vendor-defined analog pressure data (unused) |

**Timing.** Mouse look runs off a fixed 125 Hz tick rather than reacting to report arrival,
so the camera pans at a constant speed even when the receiver coalesces or drops reports
while the stick is held still.

**Sub-pixel motion.** macOS truncates the mouse *delta* field to whole pixels — a posted
`0.25` arrives as `0`, measured directly. A gentle push produces well under one pixel per
tick, so rounding each tick independently floors it to zero and slow pans feel dead and
then jump. ps2mc keeps the remainder and spends it once it reaches a whole pixel. Absolute
cursor position has no such limit and does carry fractional values, so it advances by the
exact amount every tick.

**Dead-reckoned cursor.** The pointer position is tracked internally rather than re-read
from the window server each tick. The system's copy does not reflect motion ps2mc has just
posted — at 125 Hz only 3 of 200 posted 1 px moves were visible in the very next read — so
building each event's position from it means working off a lagging base. That read can also
block for tens of milliseconds, which is not something to have in a hot path running 250
times a second. Position is re-seeded from the real cursor whenever the stick returns to
rest, so moving the physical mouse in between is picked up rather than fought, and it is
clamped to the active displays so a long push cannot walk it off into empty coordinate
space.

**Why sensitivity affects smoothness.** Because deltas are whole pixels, a pan of *N* px/s
reaches the game as *N* discrete steps per second. Smoothness at low speed is a function of
how many pixels the driver moves, not how clean its arithmetic is. The defaults were raised
from 1100 to 2800 px/s for exactly this reason: at 1100 a 360° turn took over two seconds,
which is both sluggish to play and precisely the regime where individual pixel steps become
visible. At 2800 a full turn takes about 0.85 s and a slow pan runs roughly 190 steps/s
instead of 43.

**Smoothing.** The shaped stick vector is low-pass filtered with a time constant rather
than a fixed per-tick blend — `alpha = 1 - e^(-dt/tau)` — so the feel does not change if
you alter `pollRateHz`. The filter settles to a true zero at rest instead of creeping.

**Directional engagement.** Whether you are moving is decided on the stick's radial
distance, and which way only on its angle. Testing each axis against the threshold
separately makes a diagonal push travel 1/cos(45°) ≈ 1.41x as far as a cardinal one before
anything happens, so walking forward would engage noticeably sooner than strafing
diagonally. A direction already held is kept on a slacker bound, and a release waits out a
short grace period, so rotating the stick does not stutter the keys.

**Mouse look.** Minecraft's GLFW backend disables the cursor in-world, which makes it read
`deltaX`/`deltaY` off each event rather than the absolute cursor position. ps2mc sets those
delta fields explicitly — posting only a new absolute location would move the system cursor
and leave the camera perfectly still. While a mouse button is held the event is posted as
the matching *drag* type, so click-and-hold mining is not cancelled mid-swing.

**Stick shaping.** The deadzone is radial rather than per-axis, so a diagonal push is not
clipped into an axis-aligned one, and magnitude is rescaled across the remaining travel so
the first movement past the deadzone is slow rather than a jump.

**Safety.** Everything held is released on disconnect, on suspend, and on Ctrl-C, so
quitting mid-stride can never leave `W` latched down.

**Verification.** `ps2mc selftest` covers report decoding (including short-report and
padding-bit handling), the binding grammar, the look curve's deadzone/monotonicity/diagonal
behaviour, and config loading. It ships in the binary rather than a SwiftPM test target
because the Command Line Tools install this is built against has no usable XCTest or
swift-testing module.

**Source layout.** Three targets: `PS2MCKit` holds the engine and has no UI or CLI in it,
so the app and the tool cannot drift apart.

| File | Role |
|---|---|
| **`Sources/PS2MCKit/`** | |
| `HIDReader.swift` | IOHIDManager matching, device lifecycle, raw report capture |
| `ControllerState.swift` | Report → decoded buttons, D-pad and axes |
| `Config.swift`, `ConfigDecoding.swift` | Config model, defaults, lenient JSON decoding |
| `Actions.swift` | The `kind:value@mode` binding grammar |
| `Keycodes.swift` | Key name → ANSI virtual keycode |
| `Engine.swift` | State diffing, action dispatch, stick shaping, smoothing, hotbar, suspend |
| `EventSynth.swift` | CGEvent construction, dead-reckoned cursor, quantisation |
| `DriverController.swift` | Threaded runtime shared by both frontends |
| `ButtonOrderLearner.swift` | Calibration state machine, shared by both frontends |
| `Permissions.swift` | TCC checks and prompts |
| `SelfTest.swift` | Built-in checks |
| **`Sources/PS2MCApp/`** | |
| `PS2MCApp.swift` | App entry point, menu bar item |
| `AppModel.swift` | Observable state: config, driver, permissions, validation |
| `MainView.swift`, `ControllerView.swift` | Window chrome, status, live pad view |
| `BindingsView.swift`, `TuningView.swift` | Editors |
| `CalibrationView.swift` | Calibration sheet and its scoped HID session |
| **`Sources/ps2mc/`** | |
| `main.swift`, `Monitor.swift`, `Calibrator.swift` | CLI commands |

**Threading.** The driver runs on its own `.userInteractive` thread with a private run
loop, not on the main thread. In the app that keeps a 250 Hz tick away from layout and
rendering — anything that preempts the tick shows up directly as uneven camera movement —
and in the CLI it means `start()` returns instead of blocking. Callbacks are delivered on
the main queue so the UI can consume them without hopping.

**Bundling.** There is no Xcode here, so `scripts/build-app.sh` lays out `Contents/`
by hand and ad-hoc signs it; `scripts/make-icon.swift` draws the icon into a `CGContext`
and `iconutil` packs it, rather than checking a binary `.icns` into the repo. One trap
worth knowing: the CLI ships at `Contents/Resources/ps2mc`, not `Contents/MacOS/ps2mc`,
because the volume is case-insensitive and `MacOS/ps2mc` is the same path as
`MacOS/PS2MC` — copying it there silently overwrites the app binary. The build script
compares bytes afterwards to catch exactly that.

---

## Using it for ROS instead

This repo maps the pad to keyboard and mouse, which is a fine way to drive teleop nodes
that already read the keyboard (`teleop_twist_keyboard` and friends) — point `move` at
whatever keys your node expects and give the other stick `role: "none"`.

For real ROS work you usually want the axes as a `sensor_msgs/Joy` topic rather than
synthetic keystrokes. `ControllerState.decode` is the reusable part: it is a pure function
from the 27-byte report to normalised axes and named buttons, with no macOS dependency
beyond Foundation.

---

## Licence

MIT. See [LICENSE](LICENSE).
