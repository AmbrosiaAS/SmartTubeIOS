# Xcode Cloud setup

## 1. Getting past "Connect Source Code Repository"

When you onboard from Xcode, the **Connect Source Code Repository** sheet lists
`AmbrosiaAS/SmartTubeIOS` as connected and `google/app-check` and
`google/gtm-session-fetcher` as **Not connected**, with **Next** greyed out.

**This is not a permissions problem, and granting the Xcode Cloud GitHub App
"All repositories" will not fix it.** On GitHub, "All repositories" means *all
repositories owned by the resource owner* — in this case the `AmbrosiaAS`
account. It does not, and cannot, extend to repositories in the `google`
organization. There is no setting on your side that turns those two rows green,
because installing the Xcode Cloud GitHub App on `google/app-check` would
require org-owner rights in Google's GitHub organization.

You do not need them. Both repositories are public, and Apple's own
documentation is explicit that this is enough:

> Xcode Cloud supports Swift packages and dependencies that you manage using Git
> submodules without any separate configuration if their repositories are
> publicly accessible.
>
> — [Making dependencies available to Xcode Cloud](https://developer.apple.com/documentation/xcode/making-dependencies-available-to-xcode-cloud)

The sheet is enumerating every repository in the resolved package graph and
demanding a connection record for each, rather than skipping the public ones.
Both packages arrive transitively through `firebase-ios-sdk` (see
`SmartTubeIOS/Package.swift`); nothing in this repository references them
directly.

### Two ways through

**Option A — onboard from App Store Connect instead of Xcode (recommended).**
App Store Connect only asks for the primary repository, so the sheet that is
blocking you never appears:

1. App Store Connect → your app → **Xcode Cloud** → **Get Started**.
2. Select `AmbrosiaAS/SmartTubeIOS` and grant access.
3. Pick the `SmartTube` scheme and create the workflow.
4. Set the environment variables in §3 before the first build.

**Option B — retry the Connect flow in a private window.** The
`Connect…` → GitHub authorization handoff is known to loop or silently no-op
when Safari holds a stale or multi-account GitHub session. Opening the flow in a
**Safari Private window** and authorizing there is the
[reported fix](https://developer.apple.com/forums/thread/716431). Worth one
attempt; if it still loops, use Option A.

Either way, Apple's documented fallback applies if a dependency really is
unreachable at build time:

> Finish the initial onboarding workflow for the project in Xcode and connect
> the instance that hosts your app's code, then let the first build fail. After
> the build failure, Xcode suggests a fix to connect the other instance.

You will not hit that here, because both packages are public.

> **Note.** Why the sheet flags these two and not the other ~10 Firebase
> transitive dependencies (`GoogleUtilities`, `promises`, `nanopb`, `abseil`,
> `leveldb`, `swift-protobuf`, …) cannot be determined from this repository —
> it depends on the resolution state in your local DerivedData. It is consistent
> with Xcode having performed a live resolution because there is no committed
> lockfile, which §2 fixes.

## 2. Commit `Package.resolved` — required

Xcode Cloud does not resolve packages the way your Mac does:

> Xcode Cloud doesn't use automatic package resolution and instead relies on the
> `Package.resolved` file to resolve your dependencies. If you use Swift package
> dependencies in your project, make sure to include the `Package.resolved` file
> in your Git repository and commit any changes to it. Don't include the file in
> your `.gitignore` file.

This repository had **no `Package.resolved` at any location, and never has** —
`.gitignore` contained both `*.resolved` and `*.xcworkspace/`, which between
them blocked every valid path. Those rules have been removed; per-user state is
still ignored via the existing `xcuserdata/` and `*.xcuserstate` rules.

Because `SmartTubeIOS/Package.swift` declares `firebase-ios-sdk` as
`from: "12.0.0"`, an unpinned build floats to whatever the newest 12.x is on the
day it runs, along with all ~12 transitive Google packages. Generate and commit
the lockfile **on a Mac** — it cannot be produced on Linux, and it must never be
hand-written, since it stores exact commit revisions:

```sh
xcodebuild -resolvePackageDependencies \
    -workspace SmartTube.xcworkspace \
    -scheme SmartTube

git add -f SmartTube.xcworkspace/xcshareddata/swiftpm/Package.resolved
git commit -m "Pin Swift package dependencies for Xcode Cloud"
```

If your Xcode Cloud workflow builds the project rather than the workspace, also
commit
`SmartTubeApp/SmartTubeApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
Committing both is harmless and removes the ambiguity.

Consider tightening `Package.swift` to `.upToNextMinor(from: "12.x.y")` so
routine `Update to Latest Package Versions` runs cannot silently take a Firebase
minor bump into a release build.

## 3. Workflow environment variables

| Variable | Required | Purpose |
| --- | --- | --- |
| `GOOGLE_SERVICE_INFO_PLIST_BASE64` | Strongly recommended | Base64 of the iOS `GoogleService-Info.plist`. Mark it **secret**. |

`SmartTubeApp/SmartTubeApp/GoogleService-Info.plist` is gitignored but is a
member of the `SmartTube` target's Resources build phase and is the `-gsp`
argument to its Crashlytics run script, so a clean checkout cannot build without
it. `ci_scripts/ci_post_clone.sh` writes it from this variable:

```sh
base64 -i SmartTubeApp/SmartTubeApp/GoogleService-Info.plist | pbcopy
```

If the variable is unset, the script falls back to the committed tvOS plist at
`SmartTubeApp/Smart Tube/GoogleService-Info.plist` — both apps use the bundle id
`com.void.smarttube.app`, so it is a valid stand-in — and logs a warning. If
neither is available it fails the build with an actionable message rather than
letting xcodebuild report a missing resource much later.

## 4. Suggested workflows

Schemes are already shared under
`SmartTubeApp/SmartTubeApp.xcodeproj/xcshareddata/xcschemes/`, so both apps are
selectable.

| Workflow | Start condition | Actions |
| --- | --- | --- |
| PR validation | Pull request to `master` | Build `SmartTube` (iOS) + `Smart Tube` (tvOS) |
| TestFlight | Push to `master` | Archive `SmartTube` → TestFlight (internal) |

Note that `SmartTube.xctestplan` contains only `SmartTubeUITests`, and those
tests lean on AirPlay, live network and playback benchmarks
(`AirPlayUITests`, `TVVideoPlaybackBenchmarkUITests`,
`BotGuardLivePipelineUITests`). They are a poor fit for a required PR gate. The
86 fast unit tests in `SmartTubeIOS/Tests/SmartTubeIOSTests` are not reachable
from any scheme — wiring them into a test plan is the higher-value next step if
you want a meaningful test gate.

## 5. Project changes made for Xcode Cloud

- **tvOS signing.** `Smart Tube` used `CODE_SIGN_STYLE = Manual` with
  `PROVISIONING_PROFILE_SPECIFIER[sdk=appletvos*] = "Smart Tube TV"`. Xcode
  Cloud manages signing itself and requires automatic signing, so the target now
  matches the others: automatic, `DEVELOPMENT_TEAM = 5A4JA438MW`, no pinned
  profile. **This changes local tvOS signing too** — the named profile is no
  longer used.
- **`CODE_SIGN_IDENTITY`.** Eight configurations pinned the legacy
  `"iPhone Developer"` alias, including Release. A hardcoded development
  identity fights cloud-managed distribution signing at archive time. All are
  now `"Apple Development"`, the modern equivalent.
- **Crashlytics run scripts.** Both had the bare invocation
  `"${BUILD_DIR%Build/*}SourcePackages/…/Crashlytics/run"`, which fails with an
  opaque `not found` if package resolution did not land where expected. They now
  check for the binary and the plist first and emit a real error. The **tvOS**
  phase also pointed at the *iOS* target's plist
  (`$SRCROOT/SmartTubeApp/GoogleService-Info.plist`); it now uses
  `$SRCROOT/Smart Tube/GoogleService-Info.plist`.
- **Malformed package product dependency.** The
  `XCSwiftPackageProductDependency` for `SmartTubeIOS` on the main `SmartTube`
  target was missing its `package =` back-reference to the
  `XCLocalSwiftPackageReference`, unlike its three siblings. Xcode's UI tolerates
  this by matching on product name; a clean CI checkout is where it bites. Fixed.

## 6. Known issues not addressed here

- `SmartTubeApp/Smart Tube/GoogleService-Info.plist` is **committed** with a live
  `API_KEY`, `GOOGLE_APP_ID` and `PROJECT_ID`, contradicting both `README.md`
  ("Both files are gitignored and will never be committed") and the checklist in
  `.github/PULL_REQUEST_TEMPLATE.md`. Firebase treats these values as client
  identifiers rather than secrets, so this is not an emergency, but the docs and
  the repository disagree and one of them should change.
- `README.md` describes a `SmartTubeApp/Config/Secrets.xcconfig` workflow that
  the project does not implement — there is no `baseConfigurationReference`
  anywhere in `project.pbxproj`, and `DEVELOPMENT_TEAM` is hardcoded in ten
  places.
- Both app targets `import FirebaseCore` without declaring a product dependency
  on it, relying on it being transitively in the module search path via
  `FirebaseCrashlytics`. This works today but will break on a Firebase
  restructure.
