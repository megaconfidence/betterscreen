# BetterScreen

macOS menu-bar app that uses a camera as an ambient light meter to drive external
monitor and built-in display brightness. Built with SwiftPM; there is deliberately
no `.xcodeproj`.

Target is macOS 15+. `Package.swift` pins `swiftLanguageMode(.v5)` on purpose:
AVFoundation delegates, IOKit serial queues and timers do not model cleanly under
Swift 6 strict concurrency, so isolation is enforced by explicit queue discipline
instead. Do not "fix" this by enabling Swift 6 mode.

## Build and run

```
./Scripts/bundle.sh                 # build, sign into dist/
./Scripts/bundle.sh --debug --run   # debug build and launch
./Scripts/bundle.sh --logs          # stream os_log
./Scripts/make-signing-cert.sh      # one-time, stable TCC identity
```

`swift build` alone is fine for checking compilation, but **never `swift run`** for
anything touching the camera or brightness. Those paths need the signed bundle.

**Always launch via `open`**, never `dist/BetterScreen.app/Contents/MacOS/BetterScreen`.
A direct exec makes TCC attribute the camera grant to the terminal instead of the app.

`Scripts/bundle.sh` and `Scripts/make-signing-cert.sh` carry detailed comments on
why the hardened runtime, App Sandbox and ad-hoc signing are all deliberately
avoided. Read them before changing signing, entitlements or `Info.plist`.

## Diagnostics

Every layer has a CLI mode, dispatched in `App.swift`. All require the bundle:

```
open --stdout /tmp/x.log --stderr /tmp/x.log dist/BetterScreen.app --args --diagnose
```

| Flag | Purpose |
| --- | --- |
| `--diagnose` | Display enumeration, classification, IORegistry matching, live DDC read |
| `--test-ddc` | Writes brightness through several levels and reads back |
| `--set-brightness N` | Sets all controllable displays to N% |
| `--snapshot` | One frame per camera: mean luminance, uniformity, ASCII preview, PNG |
| `--watch-light` | 60s light-meter probe, exposure locked then auto as a control |
| `--test-sensor` | Uses the display itself as the light source |

## Traps that have already cost time

- **`log` is a zsh builtin** that shadows the real tool and silently produces
  nothing. Always `/usr/bin/log`.
- **`.debug` os_log messages are never persisted.** `log show` after the fact only
  replays `info` and above, so control-loop detail is lost unless you were already
  running `log stream --level debug`. Capture the stream *before* reproducing.
- **stdout is block-buffered** when launched via `open`, because it is a file rather
  than a TTY. `App.swift` calls `setvbuf(..., _IOLBF, 0)` for exactly this reason —
  without it output appears only when the 4KB buffer fills, and is lost entirely on
  a crash. Do not remove it.
- **`String(format:)` with `%s` and a Swift `String` segfaults.** It strlens a
  bridged NSString pointer. Use `%@`.
- **DDC reads fail ~12% of the time**; writes are reliable at ~3ms. No control path
  may depend on a read succeeding. Reads are for diagnostics only.
- **`DisplayServicesSetBrightness` returns success for displays it cannot drive.**
  Always gate on the corresponding `Get` succeeding first.
- **`--test-sensor` is meaningless when the webcam sits on top of the monitor**
  facing the user: monitor light never reaches it. Useful for confirming absence of
  a feedback loop, useless as a sensor test.

## Platform facts worth not rediscovering

- `IOAVServiceCreateWithService` / `ReadI2C` / `WriteI2C` are public exports in the
  SDK's `IOKit.tbd`. No entitlement, no `dlopen`, no root. The typedef must be named
  `IOAVService`; `IOAVServiceRef` trips "obsoleted in Swift 3".
- `CGSIsHDRSupported` / `CGSIsHDREnabled` exist in `CoreGraphics.tbd` but Swift
  cannot model `weak_import`, so they must be `dlsym`'d.
- `DisplayServices.framework` is private; reach it via `dlopen`.
  `DisplayServicesBrightnessChanged` does not exist on macOS 26.
- Apple's EDID PnP vendor ID is `0x0610`, not the USB `0x05AC`.
- DDC checksum seeds are asymmetric: set `0x6E ^ 0x51`, get `0x6E`, reply `0x50`
  over bytes 0…9 compared against `reply[10]`. Read exactly 11 bytes.
- **Absolute scene luminance is unobservable on macOS.** `exposureDuration`, `ISO`,
  `lensAperture`, `exposureTargetOffset` and `setExposureModeCustom...` are all
  `API_UNAVAILABLE(macos)`; frame buffers carry no exposure metadata; AE has already
  converged by the first delivered frame. Hence the anchored-relative design: lock
  exposure, report light relative to the locked anchor in stops.

## Architecture

- `Ambient/` — `AmbientLightSensor` (capture, exposure lock, anchoring, re-ranging),
  `FrameLuma` (sRGB EOTF + Rec.709 mean, clipping fractions), `CameraSnapshot`.
- `Display/` — `DDCTransport` (I2C wire format, serialised), `AVServiceLocator`
  (IORegistry walk, `IODisplayLocation` match), `DisplayInfo`, `ManagedDisplay`
  (classification, brightness), `DisplayManager` (hotplug/wake rescan),
  `DisplayServicesSPI`, `CoreGraphicsSPI`.
- `Control/` — `BrightnessCurve` (anchor + response in stops + learned offsets),
  `BrightnessController` (stability delay, change threshold, smoothstep ramps).
- `Support/` — `Settings` (atomic debounced JSON), `Log` (os_log, subsystem
  `com.betterscreen.app`, categories `app` `display` `ddc` `ambient` `control`).
- `UI/` — `NSStatusItem` menu plus SwiftUI settings.

## Conventions

- Comments explain **why**, not what, and cite the measurement or failure that
  motivated the code. Several comments record verified numbers; keep that style and
  update the numbers if behaviour changes.
- Anything on the control path that makes a decision must log it. A silent decision
  is undebuggable — an unlogged control path is precisely why a first-run bug went
  unnoticed while looking like a working feature.
- The sensor flags readings it cannot trust via `isReliable`. Consumers must honour
  it; acting on an untrusted reading drives the display to an extreme.
- Never claim a behaviour works without a log line or hardware read showing it.
  See the `verify-brightness-loop` skill before doing hardware verification.

## Commit messages

Single-line semantic commits, no body:

```
type: imperative summary
```

Lowercase after the colon, no trailing period, 72 characters or fewer. Types in
use: `feat` `fix` `docs` `refactor` `perf` `test` `build` `chore`.

```
feat: add camera-based auto-brightness menu bar app
fix: prevent gain drift and anchor curve to display brightness
docs: add project rules and brightness verification skill
```

Reasoning that would have gone in a commit body belongs in a comment next to the
code it explains, where it stays visible during editing rather than only in
`git log`.
