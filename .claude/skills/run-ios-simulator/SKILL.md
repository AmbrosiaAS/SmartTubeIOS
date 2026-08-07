---
name: run-ios-simulator
description: Run, build, launch, screenshot, click and test the SmartTube iOS app and its CarPlay display on the Xcode-VM simulator, with a queue that prevents two sessions colliding. Use for "run the app", "launch the simulator", "screenshot CarPlay", "click in CarPlay", "run the tests", "the CarPlay screen is black", or any simulator work on this machine.
---

# Driving the iOS Simulator on Xcode-VM

All simulator work goes through one driver: **`.claude/skills/run-ios-simulator/simq`**
(paths in this file are relative to the repo root). It wraps `simctl`,
`xcodebuild` and the CarPlay display, and every subcommand that touches the
simulator takes an exclusive FIFO lock first.

**Why the lock is not optional.** This host fits exactly one busy simulator
(6 cores / 14 GB, and `carkitd` burns a whole core whenever a CarPlay display is
provisioned). Two sessions at once does not merely run slow, it *corrupts
results*: `xcodebuild test` installs and launches a test host, which terminates
the app the other session is driving, and that session then reports a phantom
crash or nonsense timings. This has already happened here.

**Machine-gated.** `simq` refuses to run unless the host is **Xcode-VM**
(`ComputerName`; fingerprint `hw.model VirtualMac2,1`, `IOPlatformUUID
4B085935-4672-5C7F-8FEC-2B57429C94C2`). The device names, the CarPlay recovery
steps and the lock path are all specific to this host — elsewhere they would
fight another machine's simulators instead of queueing with them. It exits 3
with an explanation on any other machine.

## Start here

```bash
.claude/skills/run-ios-simulator/simq doctor
```

Prints the machine gate, Xcode version, booted devices, whether the CarPlay
window exists, load average, whether the gitignored Firebase plist is in place,
and who holds the lock. Run it first; it diagnoses most failures before you hit
them.

## Agent path — driving the app

```bash
S=.claude/skills/run-ios-simulator/simq

$S build                  # xcodebuild, under the lock
$S install                # install the built .app (never erases the device)
$S launch --cold          # terminate, then launch with the CarPlay-safe flag
$S shot                   # screenshot the CarPlay display -> .simq-shots/
$S shot --phone           # screenshot the phone screen instead
$S shot path/to/out.png   # explicit destination
$S click 203 283          # click the CarPlay display at framebuffer pixel
$S logs                   # last 5 min, BOTH app subsystems, untruncated
$S logs "History loaded"  # ...filtered by message substring
SIMQ_LOG_WINDOW=20m $S logs   # widen the window
$S status                 # lock holder + queue, booted devices, install state
$S run -- <any command>   # hold the lock while running anything else
```

A real session, verified end to end:

```bash
S=.claude/skills/run-ios-simulator/simq
$S launch --cold
sleep 6
$S click 203 283                       # the SmartTube icon on the CarPlay home screen
sleep 5
$S shot .simq-shots/root.png           # -> CarPlay root menu
$S click 275 316                       # the History row
sleep 7
$S shot .simq-shots/history.png        # -> History list with thumbnails
$S logs | grep -i carplay              # -> "[CarPlay] History loaded 15 videos"
```

**Click coordinates are CarPlay framebuffer pixels** in the 800×480 image that
`shot` produces — read them straight off the screenshot. `simq` converts to
screen points itself by reading the window's AXGroup live (see Gotchas).

### Tests

```bash
.claude/skills/run-ios-simulator/simq tests -only-testing:SmartTubeIOSTests/CarPlayItemFormattingTests
```

Verified: `Test run with 12 tests in 2 suites passed` / `** TEST SUCCEEDED **`.
Omit `-only-testing:` for the whole suite — it is ~840 tests and takes minutes,
and about 20 failures are pre-existing and unrelated to CarPlay.

### When the CarPlay screen is black

```bash
$S carplay status     # window, AXGroup origin, framebuffer health
$S carplay recover    # drop the display and re-provision it
```

`carplay status` distinguishes the two black-screen causes: a broken capture
versus a genuinely dead display. A healthy external screen has a class-1 port
with a live 800×480 `IOSurface`; a zombie one has none and `carkitd` logs
`pixelSize {0, 0}` in a tight loop while pegging a core.

## Human path

Open `SmartTube.xcworkspace` in Xcode and run the `SmartTube` scheme. Useful for
debugging with breakpoints; useless for automation, and it bypasses the lock, so
don't do it while an agent session is driving the simulator.

## Gotchas

These are all things that cost real time here.

- **`simctl io screenshot --display external` is the only capture that works**
  for the CarPlay screen. The numeric forms (`--display 2`, `--display 3`) hang
  forever. `screencapture` fails with "could not create image from display"
  without a TCC Screen Recording grant, which cannot be fixed from the CLI.
  Simulator's *File > Save Screen* silently writes no file at all when the
  display is mis-provisioned. `--display internal` is the phone screen.
- **Clicks need the Simulator application activated first.** `simq` does this,
  but if you hand-roll a click: System Events `click at` never reaches the
  render view (it is not an accessibility control), so a CGEvent is required —
  *and* `AXRaise` on the CarPlay window is not enough, because the Claude
  desktop app window overlaps those screen coordinates and silently swallows the
  click. It looks exactly like "clicking doesn't work". Two sessions lost their
  first taps to this.
- **The AXGroup origin moves between sessions** — observed at `{87,120}` and
  `{607,148}`. It is the clickable render view *inside* the window, not the
  window frame, and it is 400×240 = half the 800×480 framebuffer. Never
  hardcode it; `simq click` re-derives it every time.
- **Match CarPlay windows on the `– CarPlay` suffix.** This project's *device*
  is named `SmartTubeIOS - carplay-menu - 1`, so a loose `grep -i carplay` over
  window titles also matches the *phone* window and you silently capture or
  click the wrong screen.
- **Target the device by UDID, never by name.** The device has been renamed
  mid-project, which broke every `-destination 'name=iPhone 17'` command. `simq`
  resolves the booted device's UDID automatically; override with `SIMQ_UDID`.
- **Never `simctl erase`.** It wipes the signed-in YouTube session, and
  re-authenticating requires the user's own credentials — an agent cannot do it.
  `simq install` deliberately installs over the top instead.
- **Rebooting the simulator does not fix a dead CarPlay display.** The zombie
  window re-attaches in the same state, and reinstalling the app doesn't help
  either. Only dropping and re-adding the display works — that's what
  `carplay recover` does.
- **Confirm which playback pipeline ran — but know when the flag matters.**
  `simq launch` passes `--uitesting-disable-tos-player-on-ios`, which forces the
  AVPlayer pipeline for **phone-initiated** playback (the phone otherwise uses
  the WKWebView TOS player, which CarPlay cannot drive). Playback started *from
  CarPlay* goes through `CarPlayBridge`, which always selects AVPlayer by
  design — so a flagless relaunch (e.g. iOS or CarPlay relaunching the app on
  its own; the flag is read from `ProcessInfo` and never persisted) does NOT
  invalidate a CarPlay-initiated trial. Verified: after a force-quit and a
  CarPlay relaunch with no arguments, the log still showed
  `setupRemoteCommandCenter (AVPlayer VM)` and `[PlayerStateStore] play`.
  Either way, check the log each trial: `[PlayerStateStore] play` is AVPlayer;
  `[TOSPlayerStateStore] play` is the web player, which invalidates any Now
  Playing measurement.
- **Stream resolution takes ~80 s** before audio starts, even on a good day. Do
  not conclude anything about progress-bar timing until playback has actually
  begun.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `refusing to run — this skill manages simulator sessions on 'Xcode-VM' only` | You are on another host. That is intentional. |
| `no booted simulator (and SIMQ_UDID not set)` | `xcrun simctl boot <udid>`, then retry. `simq doctor` lists devices. |
| `simq: waiting for simulator — held by pid N` | Another session has the lock. It queues FIFO and proceeds automatically. `scripts/simlock status` shows the holder. |
| Build fails: `Build input file cannot be found … GoogleService-Info.plist` | The plist is gitignored. `cp "SmartTubeApp/Smart Tube/GoogleService-Info.plist" SmartTubeApp/SmartTubeApp/` |
| CarPlay screenshot is a black image | `simq carplay status`; if the framebuffer is unhealthy, `simq carplay recover`. |
| Clicks appear to do nothing | The Simulator app was not frontmost, or the AXGroup moved. `simq click` handles both — if you bypassed it, don't. |
| `could not read the CarPlay AXGroup` | No CarPlay window. `simq carplay recover`. |
| Every video fails with `LOGIN_REQUIRED` / "Sign in to confirm you're not a bot" | The YouTube session hit an account-level bot check. Only the user can fix it by signing in again in the app; an agent must not enter credentials. |
| `simq terminate` says "was not running" | Not an error — it exits 0. |

## Files

- `.claude/skills/run-ios-simulator/simq` — the driver.
- `.claude/skills/run-ios-simulator/click.swift` — CGEvent clicker; `simq`
  compiles it to `$TMPDIR/simq-click` on first use and recompiles when it
  changes. Needs Xcode command line tools.
- `scripts/simlock` — the FIFO lock primitive `simq` funnels through. Usable
  directly for non-simulator work that still needs exclusivity:
  `scripts/simlock run --label "what I'm doing" -- <command>`.
- `.simq-shots/` — default screenshot destination (gitignored).
