# SmartTubeIOS — working notes for Claude

## The iOS Simulator is a shared, single-slot resource — always take the lock

This machine (6 cores / 14 GB) has room for exactly **one** busy simulator, and
`carkitd` burns a whole core on its own whenever a CarPlay display is
provisioned. Two sessions using the simulator at once does not merely slow
things down, it **corrupts results**: `xcodebuild test` installs and launches a
test host, which terminates the app another session is driving, and the victim
session then reports a phantom "crash" or bogus timings.

Serialise every simulator-touching command through `scripts/simlock`:

```bash
scripts/simlock run --label "what I am doing" -- <command>
```

That covers `xcodebuild build`/`test`, `simctl install`/`launch`/`terminate`,
screenshots, and UI automation. It waits for its turn (FIFO, so a queue can't
starve anyone), runs the command, and releases the lock on **any** exit path —
including failure, `^C`, and `SIGTERM`. A lock whose owner died is detected and
broken automatically, so a killed session cannot wedge the machine.

```bash
scripts/simlock status          # who holds it, who's waiting
scripts/simlock release --force # last resort, only if status looks wrong
```

Long multi-step work that spans several shell invocations can use
`simlock acquire` / `simlock release` instead, but prefer `run`.

**Subagents must be told to use it** — put the `simlock run` form directly in
the agent's prompt, because an agent that doesn't know about the lock will
happily collide with everyone else.

## Simulator facts worth not rediscovering

- iOS app scheme is `SmartTube` (NOT "Smart Tube" — that's tvOS); bundle
  `com.ambronet.smarttube`.
- Unit tests: `cd SmartTubeIOS && xcodebuild test -scheme SmartTubeIOS-Package
  -destination 'platform=iOS Simulator,id=<udid>'`. The `SmartTubeIOS` scheme
  has no test action. Prefer targeting the simulator by **id**, not by name —
  names get changed.
- Building requires the gitignored `SmartTubeApp/SmartTubeApp/GoogleService-Info.plist`;
  copy it from `SmartTubeApp/Smart Tube/GoogleService-Info.plist` (same bundle id).
- Never build with `CODE_SIGNING_ALLOWED=NO` — the CarPlay audio entitlement
  must be embedded or the CarPlay scene never connects.
- Launch with `--uitesting-disable-tos-player-on-ios` when testing anything
  CarPlay-related, so playback uses the AVPlayer pipeline rather than the
  WKWebView TOS player. Verify from the log: `[PlayerStateStore] play` means
  AVPlayer (correct); `[TOSPlayerStateStore] play` means the flag was lost and
  the test is invalid.
- CarPlay screenshots: `xcrun simctl io <udid> screenshot --display external
  <path>` gives the true 800×480 framebuffer. The numeric `--display 2`/`3`
  forms hang.
