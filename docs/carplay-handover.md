# CarPlay feature — handover

Branch `carplay-menu`. PR [#2](https://github.com/AmbrosiaAS/SmartTubeIOS/pull/2)
is **merged**; PR [#3](https://github.com/AmbrosiaAS/SmartTubeIOS/pull/3) is
**open** with the later work.
Written 2026-08-08. Read `CLAUDE.md` first (simulator lock is mandatory), then this.

---

## 1. What this feature is for

A 2016 **Mazda 3 with MZD Connect** whose **touchscreen is broken**. The rotary
commander knob is the only input, always. Everything below follows from that:

- Flat `CPListTemplate`s, no tabs/grids, ≤3 levels deep. iOS drives knob focus
  itself — there is no focus API, so structure is the only lever.
- MZD hardware: knob press = play/pause, knob rock = track skip, dedicated Back
  button pops templates. On-screen transport buttons are secondary.
- Requested and delivered: a **Now Playing** button showing progress in the
  current title, **±15 s skip**, a **link to the queue**, and the ability to
  **play individual items from Watch Later or History**.
- Queue semantics (settled after several rounds of clarification): the queue
  **starts empty each launch**; picking a History/Watch Later row **appends that
  one video and plays it** — it does not replace the queue with the whole list.
  Re-picking an already-queued row plays it from its existing position.

**This fork is CarPlay-first.** Where CarPlay and phone-native behaviour
conflict, CarPlay wins.

---

## 2. Repo state

**Everything is committed and pushed. Working tree is clean.** Nothing is
waiting on you here.

**Merged into `master`** via PR #2 (master tip `2c8b545`):

- `eec636f` CarPlay: queue screen, append-and-play, in-motion row cap
- `24e72f1` Now Playing: fix frozen progress bar, show position immediately, add chapter name
- `97f0a8f` Add simulator queue lock and run-ios-simulator skill
- `630914a` CarPlay: fix crash from presenting an alert over an existing one
- `ea43292` CarPlay: add scripted test scenarios, document rotary-knob automation

**On `carplay-menu`, open in PR #3, not yet in master:**

- `f844410` Now Playing: report real player state instead of guessing ← the §3 fix
- `70b5983` Add launch-time hook to play the first Watch Later item
- `762e5aa` docs: CarPlay handover (this file)

Note PR #2 was merged *before* those three landed, which is why they needed a
second PR — don't assume a single PR carries the whole feature.

---

## 3. The progress-bar problem — the most important finding

The user's complaint was: *"Pressing the play button caused the now-playing
progress bar to advance, yet no audio was heard… This now playing bar is
misleading, it should be an accurate display of where the playback position
actually is. Instead of a guess that is so inaccurate, it does not know if an
item is playing or not."*

They were right, and the cause was a previous fix of mine.

**Mechanism.** The system draws the CarPlay/lock-screen bar as
`elapsed + rate × wall-clock` from the last values published to
`MPNowPlayingInfoCenter`. The old code derived both the rate and
`playbackState` from `PlaybackViewModel.isPlaying` — which is an **intent flag
set the moment playback is requested**, not a report of the player. So during
the ~90 s while a stream resolved, the app asserted ".playing at rate 1" and the
system extrapolated a smooth, confident, entirely fictional position.

Caught red-handed in the simulator: the head unit showed **5:53 elapsed with a
pause glyph** while the log showed the player rate had never been set once.
5:53 was exactly the wall-clock time since the request.

**Fix** (`PlaybackViewModel+NowPlaying.swift`, commit `f844410`): playback state
and rate now come from `AVPlayer.timeControlStatus`:

```swift
private var actualPlaybackState: MPNowPlayingPlaybackState {
    switch player.timeControlStatus {
    case .playing:                      return .playing
    case .paused:                       return .paused
    case .waitingToPlayAtSpecifiedRate: return .paused   // no "buffering" state exists
    @unknown default:                   return .paused
    }
}
var publishablePlaybackRate: Double {
    player.timeControlStatus == .playing ? Double(player.rate) : 0
}
```

**Observing `timeControlStatus` is REQUIRED, not just `rate`.** `play()` sets
`rate` to 1 immediately while the status sits at
`.waitingToPlayAtSpecifiedRate`, and the later flip to `.playing` changes no
rate at all. A rate-only observer never hears the moment playback truly begins,
so the bar would sit reporting "paused" over audible audio. Hence
`setupTimeControlObserver()` in `PlaybackViewModel+Observers.swift`.

**Verified:** the same failing video now reads `0:00 / -44:42` with a ▶ glyph and
stays there until audio genuinely starts. `NowPlayingCommandsTests` +
`PlaybackEndAutoplayTests` — 16 tests pass.

### Do not "re-fix" the frozen bar by trusting isPlaying again

There is a real, separate bug this replaced: without any explicit
`playbackState`, CarPlay shows a ▶ glyph and refuses to extrapolate at all, so
the bar latches on its first value and only jumps on a seek. Both bugs are now
handled — publish real state, and publish it whenever `timeControlStatus`
changes.

---

## 4. A wrong conclusion I reached — don't repeat it

Mid-investigation I concluded: *"playback never starts; the background quality
upgrade replaces the working muxed item with a candidate that fails
`loadTracks`, and never restores it."* **That was wrong.** Corrected with logs:

- `readyToPlay` fired at 15:15:15 and playback ran continuously for 35+ minutes
  afterwards. My "never plays" screenshot was taken at 15:14 — a minute *before*
  the stream resolved.
- The absence of `[loadAsync] setting rate` was a red herring. The fallback path
  sets the rate at `PlaybackViewModel+Fallback.swift:1142`
  (`attemptURL`'s `.readyToPlay` handler) **without emitting that log line**.

So the muxed→upgrade rollback path is **not** a confirmed bug. It may still be
worth hardening (it does swap `player.currentItem` for an unproven candidate and
only restores `isMuxedFallback` + the format list on failure, not the item) but
there is **no evidence it breaks playback**. Do not "fix" it without a
reproduction.

**Lesson for the next session:** in this app, "no log line" ≠ "did not happen" —
the load pipeline has many paths with inconsistent logging. Confirm player state
from `timeControlStatus` / the honest bar, not from log absence.

---

## 5. Driving the rotary knob in the iOS Simulator — this works

Fully calibrated on this host. The Simulator's CarPlay window has a **knurled
knob widget below the screen**; it is the rotary commander.

Enable via *I/O → External Displays → CarPlay…* — the **TV Out Extended Setup**
dialog has `Back Button`, `Home Button`, **`Knob`**, **`Knob nudge`**,
**`Touch screen`**, `Touch screen is lo-fi` (Width 800 / Height 480 / Scale 2).
`Knob` is on by default. Click **Run**.

| Input | Mapping |
|---|---|
| **Rotate** = press-and-drag an arc around the knob centre | **60° of arc = exactly one focus detent.** Clockwise (top→right→bottom) moves focus down |
| **Press** = plain left-click on the knob centre | Selects the focused row / activates the focused button |

Use **computer use** (`mcp__computer-use__*`, Simulator granted at full tier),
batching the whole arc into one `computer_batch`: `mouse_move`,
`left_mouse_down`, several `mouse_move` steps around the circumference,
`left_mouse_up`.

**Ignored — do not retry:** `scroll` over the knob, arrow keys with the CarPlay
window focused, and `left_click_drag` (a straight chord is unreliable).

Behaviour worth knowing:

- The focused row draws a bright rounded highlight — that is how you know knob
  input landed.
- The **first** rotation in a freshly pushed template *lands* focus on row 1
  rather than moving it.
- Lists **auto-scroll** to keep focus visible, so rows below the fold are
  reachable.
- On `CPNowPlayingTemplate` the focus order is **Queue (Up Next) → −15 →
  play/pause → +15**, and it **does not wrap** — rotate counter-clockwise to
  reach the Up Next button.
- The nav-bar back chevron shows **no visible focus ring**. Not a real gap: the
  car has a dedicated hardware Back button.
- Unchecking `Touch screen` makes the display knob-only like the user's car, but
  it is **not needed** to test focus reachability (the app cannot tell, iOS draws
  the focus ring either way) and changing it re-provisions the display, risking a
  zombie screen. Leave it alone.

**Verified end to end with knob input only:** root menu → Watch Later → row 2 →
play → Now Playing → +15 s skip → Queue.

If the host display gets resized, the knob shrinks and arcs get unreliable.
Re-derive coordinates from a fresh screenshot; enlarging the window by dragging
its corner onto empty desktop needs the **Finder** grant (otherwise the drag is
blocked as "desktop shell").

---

## 6. Physical-device and CarPlay Simulator testing — the hard limits

This took a long time to establish. **Do not re-litigate it.**

### CarPlay Simulator cannot work on this machine

`/Applications/CarPlay Simulator.app` is installed (copied from
`Additional_Tools_for_Xcode_26.6.dmg`). It launches, lists the phones under
**Sessions**, opens an "Automaker UI" head unit with a proper knob, arrow
buttons and a **Limited/Full user-interface toggle** — and then hangs forever on
*"Connecting to <device>"*. Reasons, each independently confirmed:

1. **No USB bus exists in this VM.** `system_profiler SPUSBDataType` returns
   **zero output**.
2. **Both phones are network-paired, not USB.** `xcrun devicectl list devices`
   → `transportType = localNetwork` for the iPhone 17 and iPhone 13 Pro; only
   simulators are `sameMachine`. Wired CarPlay is a USB protocol with no network
   fallback.
3. **UTM cannot fix this.** USB sharing works only on UTM's QEMU backend, not
   Apple Virtualization — and a macOS guest on Apple Silicon must use Apple
   Virtualization. iOS devices are specifically called out as not capturable.
   VirtualHere gives `devicectl` a channel without presenting a USB bus.
4. **It cannot drive the iOS Simulator either.** The simulator device appears in
   its Sessions list *only while the simulator's own CarPlay display is
   provisioned*, and is greyed out; release that display and the entry vanishes
   entirely.
5. **Even with real USB it might not work.** CarPlay Simulator hanging on
   "Connecting to phone" is an [open Apple bug since 2026-03-04](https://developer.apple.com/forums/thread/820460)
   (`CoreDeviceError 4000`, `com.apple.carkit.remote-iap.service` failing to
   open), reproducing for multiple developers on multiple Macs and iPhones with
   real cables, still broken in Xcode 27 beta 3.

**There is no wireless CarPlay simulator.** Apple's requires a USB cable.
Third-party wireless-capable head units ([pi-carplay](https://github.com/Michael-1103/pi-carplay),
[node-CarPlay](https://github.com/rhysmorgan134/node-CarPlay)) drive a
**Carlinkit dongle** — which itself plugs in over USB, so same wall.

**Conclusion: real CarPlay verification happens in the user's actual Mazda 3.**
They have the real head unit and the real knob. Emulation here is exhausted.

### What DOES work with a physical device

- **Install over the network works**: `xcrun devicectl device install app --device <udid> <path>`.
  Device build: `xcodebuild -workspace SmartTube.xcworkspace -scheme SmartTube
  -destination 'platform=iOS,id=<udid>'` — signs fine with
  "Apple Development: ambroset@outlook.com.au".
- **Launch requires the phone UNLOCKED.** Locked gives
  `FBSOpenApplicationErrorDomain error 7 Locked — "Unable to launch … because the
  device was not, or could not be, unlocked"`. This is iOS policy, not a
  permission you can be granted, and you must not ask for the passcode.
- Device UDIDs: iPhone 17 `51904531-E5CB-535C-B4BD-4E67EBF5306F`,
  iPhone 13 Pro (`Catbys Dev iPhpne`) `EEFEE7FA-1377-52C4-9664-A7AF550FDF56`.
- `xcrun devicectl device capture screenshot --device <udid> --destination <path>`
  works and is useful for checking phone state.

---

## 7. Test hooks — driving CarPlay with no pointer input

`CarPlayMenuController.runTestScenarioIfRequested()` runs a scripted template
sequence on CarPlay scene connect and logs under `[CarPlayScenario]`:

```bash
xcrun simctl launch <udid> com.ambronet.smarttube \
  --uitesting-disable-tos-player-on-ios \
  --uitesting-carplay-scenario=<name>
```

| Scenario | Purpose | Status |
|---|---|---|
| `double-alert` | regression guard for the present-over-presented crash | **passes** — `double-alert survived — no uncaught exception` |
| `queue-twice` | duplicate queue push | **passes** |
| `play-watch-later-first` | plays the first Watch Later row via the same path as the row handler; works with the phone locked | works |

These still need a **working CarPlay display** (the hook fires on scene
connect); they remove the need for *input*, not for a screen. You must still
click the app icon on the CarPlay home screen once to connect the scene.

`--uitesting-play-watch-later-first` in `AppEntry.swift` (commit `70b5983`) is the
launch-time equivalent for a **physical device**, where no head unit exists to
trigger the CarPlay scene. It plays the first Watch Later video through the same
`PlayerStateStore` path the CarPlay row handler uses, so it exercises the real
playback path without CarPlay:

```bash
xcrun devicectl device process launch --device <udid> --terminate-existing \
  com.ambronet.smarttube \
  --arg "--uitesting-disable-tos-player-on-ios" \
  --arg "--uitesting-play-watch-later-first"
```

Remember the phone must be **unlocked** for launch to be permitted (§6).

---

## 8. Tooling gotchas that cost real time

- **Take the simulator lock for everything.** `scripts/simlock run --label "…" -- <cmd>`.
  One busy simulator fits on this host; concurrent use *corrupts* results (a test
  host terminates the app another session is driving → phantom crashes). Put the
  `simlock run` form directly into subagent prompts.
- **Apple events to System Events are DENIED on this host and cannot be
  restored.** The requesting binary is a versioned
  `claude-code/<version>/claude.app` path, so the TCC grant stops matching after
  an update and macOS auto-denies without prompting. The toggle reads *on*;
  `tccutil reset AppleEvents` does not help; it is not a sandbox issue.
  Consequences:
  - `simq click`, `simq carplay status|recover` are **broken**.
  - **`simq doctor` lies** — it reports "no CarPlay window" even when the display
    is perfectly healthy. Verify with
    `xcrun simctl io <udid> screenshot --display external <path>` instead.
  - Use **computer use** for all CarPlay input and for the recover menu dance.
- **Recovering a dead/zombie CarPlay display**: *I/O → External Displays →
  Disabled*, then *I/O → External Displays → CarPlay… → Run*. Nothing else works
  — not rebooting the device, not reinstalling the app, not `killall Simulator`,
  not PlistBuddy toggling `SimulatorExternalDisplay`, and there is no `killall`
  in the sim runtime to kill `carkitd`.
- **Capture**: `xcrun simctl io <udid> screenshot --display external <path>` is
  the only thing that works for the CarPlay screen (`--display internal` = phone).
  The numeric `--display 2`/`3` forms hang.
- **Never `simctl erase`** — it wipes the signed-in YouTube session and only the
  user can re-authenticate.
- **Never build with `CODE_SIGNING_ALLOWED=NO`** — the CarPlay audio entitlement
  must be embedded or the CarPlay scene never connects.
- Build needs the gitignored `SmartTubeApp/SmartTubeApp/GoogleService-Info.plist`;
  copy from `SmartTubeApp/Smart Tube/GoogleService-Info.plist`.
- Target simulators by **UDID**, never by name — the device gets renamed.
  Current: `SmartTubeIOS - carplay-menu - 1` = `D9D8EE60-406A-44CA-986B-8A723B3F606A`.
- Unit tests: `simq tests -only-testing:SmartTubeIOSTests/<Suite>`. The full
  suite is ~840 tests with **~20 pre-existing unrelated failures**.

---

## 9. The ~90 s cold start is a SIMULATOR ARTIFACT — do not "fix" it

BotGuard cannot mint a device-attested integrity token in a simulator
(`JSContext exception: TypeError: undefined is not an object`), so it falls back
to a websafe token YouTube rejects, and
`YouTubeWebViewHLSExtractor.extractHLSURL` burns its **40 s timeout twice in
series** before the Android muxed client succeeds in ~1 s. The user confirmed
playback is **fast on two physical iPhones**.

Shortening those timeouts would optimise for a condition that only exists in the
simulator and could break real-device playback that legitimately takes 25 s.
**Leave them alone; measure on hardware before ever revisiting.**

Per-client bot checks (`LOGIN_REQUIRED` / "Sign in to confirm you're not a bot"
on WebSafari/MWEB/AndroidVR) are **routine** even in healthy sessions — the
client fallback ladder is what saves playback. Distinguish that from a hard
account-level block where *every* client fails and nothing plays.

**Standing user instruction:** if you hit rate-limiting / bot detection, **pause
for about an hour**, then resume. Google cannot tell app testing from watch bots.
Do not call the feature broken.

---

## 10. CarPlay API limits (checked against the iOS 26.5 SDK headers)

- **`CPNowPlayingTemplate` has no progress-bar API at all.** The only surface is
  `nowPlayingButtons`, the Up Next button + title, the album-artist button, and
  `nowPlayingMode` (iOS 18.4+, **sports only** — teams/scores). **Chapter notches
  on the bar are impossible.** No chapter/segment concept exists anywhere in
  CarPlay's headers (`CPRouteSegment`/`CPTrip` are road navigation). You cannot
  substitute YouTube's own bar — the system draws it from
  `MPNowPlayingInfoCenter`.
- **The template renders three text lines**: title, artist, and a smaller dimmed
  album line that appears **only** when `MPMediaItemPropertyAlbumTitle` is set
  (setting it pushes the transport row and bar down ~27 px). That album line is
  where the **current chapter name** goes; the artist line stays the channel.
  Verified live on the head unit: showed "Linux MacBook", then updated to
  "Modular Setup" as playback advanced.
- **Empty/error states MUST call `updateSections`.** Setting
  `emptyViewTitleVariants` alone never re-renders — lists hang on "Loading…"
  forever. See the `showEmptyState` helper.
- **Never pass `completion: nil`** to `pushTemplate`/`presentTemplate`/etc. A
  rejected operation is raised as an uncaught `NSGenericException`
  ("Presenting a template while a template is already presented is not
  supported") and kills the app. That was the user's crash
  (`SmartTube-2026-08-07-195350.ips`). All four call sites now pass completion
  blocks and log failures, plus an `isPresentingAlert` guard.
- **`CPListItem`'s built-in playing indicator never renders** on this head unit
  (trailing = covered by scroll chevrons; leading = displaced by the thumbnail;
  imageless rows get no slot). Mark the playing row with a
  `speaker.wave.2.fill` glyph in the image slot instead — that works, and it
  also shows in Watch Later/History lists.
- Only a **list** template may be pushed on top of `CPNowPlayingTemplate`.
- Cars cull lists in motion (commonly to 12 rows) and
  `CPListTemplate.maximumItemCount` **lies** (returns 500).
  `CarPlayMenuController` observes `CPSessionConfiguration.limitedUserInterfaces`
  and drops the row cap 30 → 12. Keep highest-value rows first.

---

## 11. TODOs

### High value

1. **Get PR [#3](https://github.com/AmbrosiaAS/SmartTubeIOS/pull/3) reviewed and
   merged** — it carries the honest-bar fix (§3). Nothing is uncommitted; this is
   just waiting on the user.
2. **Loading feedback on the Now Playing screen** — the user explicitly asked for
   it: *"Some feedback to show the video is loading (search for other
   implementations) then showing the actual video when it's playing."*
   The honest bar now correctly shows `0:00` + ▶ while resolving, but that is
   indistinguishable from "idle". You cannot add a spinner or a custom bar, so
   use the **album line** (§10): publish "Loading…" while
   `timeControlStatus != .playing` and no chapter is known, then swap to the
   chapter name (or clear it) once audio is rolling. Touches
   `applyChapterMetadata` in `PlaybackViewModel+NowPlaying.swift`. Worth checking
   how podcast/music apps word this before picking a string.
3. **Real-car verification on the user's Mazda 3** — the only remaining way to
   validate CarPlay end to end (§6). Install on the iPhone 17
   (`51904531-E5CB-535C-B4BD-4E67EBF5306F`) and have them drive it. Specifically
   confirm: does the selected Watch Later/History item actually start playing,
   and how long does it take? This is the user's original unresolved complaint —
   **it has never been confirmed on hardware.**

### Open / unconfirmed

4. **"Selected item never played" on the iPhone 17** — the user's report, still
   unexplained on hardware. In the simulator it always eventually plays (~90 s).
   Best current hypothesis: the long startup plus a bar that *claimed* to be
   playing made it look dead. Needs (3) to confirm. **Do not fix speculatively.**
5. **Wrong title on CarPlay Now Playing** — could not reproduce in 3 knob-driven
   trials, including the exact force-quit path (force-quit → relaunch from
   CarPlay → play row 1). All showed correct title, channel, and `0:00` with no
   carry-over. The supersede guards in `PlaybackViewModel+Fallback.swift`
   (~line 892 `attemptURL`, ~line 1208 adaptive attempt) appear to hold. If it
   recurs, capture `[PlayerStateStore] play — id=<id>` and compare against the
   published `MPMediaItemPropertyTitle`. **No speculative fix.**
6. **`limitedUserInterfaces` (12-row in-motion cap) is untestable here** — the
   toggle lives in CarPlay Simulator's session settings, which cannot connect
   (§6). Option: add a `--uitesting-carplay-force-limited` flag that forces
   `rowCap` to the limited value. That exercises *our* handling but cannot
   validate iOS's signal; the real check is in the car while moving.

### Nice to have / deferred

7. **CarPlay chapters list screen** — user: *"nice to have, mostly so I can see
   what topics are coming up while I'm stopped. But I doubt I'd use it much."*
   Deliberately deferred.
8. **Consider hardening `backgroundQualityUpgrade`** to restore the previous
   working player item when an upgrade candidate fails — see §4 for why this is
   **not** a confirmed bug. Only with a reproduction.
9. Filed, out of scope: CarPlay shows no error on terminal resolution failure;
   playback started in the phone's TOS/web player is invisible to CarPlay
   (`CarPlayBridge` reads `PlayerStateStore` only).

---

## 12. Working agreements with the user

- **Bundle only a few changes at a time** — *"be mindful of too many changes at
  once being harder to troubleshoot and debug."*
- **Pause playback when testing is done.**
- Audio may be enabled for testing but **keep the volume at the lowest setting**.
- The VM is theirs-for-Claude: *"This is a VM entirely for you to do development
  on, I expect you to run it and manage it as you see fit."* Computer use is
  granted (Simulator, Finder, CarPlay Simulator at full tier) — but grants are
  **session-scoped** and must be re-requested each session.
- **Do not** request System Settings access in order to change security
  permissions or click consent prompts on Claude's own behalf, even though the
  user has offered. Ask them to do it.
- The user pushes back hard and correctly when findings come only from the
  simulator. **Say plainly which platform a result came from**, and flag when a
  simulator result may be an artifact.
