---
name: verify-brightness-loop
description: Verify BetterScreen's ambient light sensor and auto-brightness loop against real hardware. Use when checking whether camera light metering, exposure lock, DDC brightness control, re-ranging or the ambient-to-brightness control loop actually work; when a light reading looks flat, stuck, drifting or implausible; when brightness moves unexpectedly or fails to move; or before claiming any sensor or brightness behaviour is working.
---

# Verifying the brightness loop on hardware

Compilation proves nothing here. Every layer of this app can look correct and be
wrong, and the failure modes mimic success closely enough that they have already
been mistaken for it. Follow the order below; each step rules out a class of fault
that would otherwise be misattributed to the next.

## Before anything else

Set a known baseline. The curve anchors to whatever brightness it finds at launch,
so testing from an unknown level makes the result uninterpretable:

```
pkill -x BetterScreen
rm -f "$HOME/Library/Application Support/BetterScreen/settings.json"
open --stdout /tmp/sb.log --stderr /tmp/sb.log dist/BetterScreen.app --args --set-brightness 75
```

Deleting `settings.json` matters: a persisted `DisplaySettings` suppresses curve
re-seeding, so a stale anchor silently survives.

## Capture logs before reproducing, not after

`.debug` messages are never written to disk. `log show` replays only `info` and
above, so the entire control-loop trace is unrecoverable unless the stream was
already running. This has destroyed evidence once already.

```
nohup log stream --style compact --level debug \
  --predicate 'subsystem == "com.betterscreen.app"' > /tmp/live.log 2>&1 &
```

`log` alone is a zsh builtin that silently produces nothing; `nohup log` happens to
bypass it, but prefer `/usr/bin/log` explicitly. Do not delete the log file between
runs — move it aside.

## Step 1: is the display controllable?

```
open --stdout /tmp/d.log --stderr /tmp/d.log dist/BetterScreen.app --args --diagnose
open --stdout /tmp/t.log --stderr /tmp/t.log dist/BetterScreen.app --args --test-ddc
```

Expect classification, an `IODisplayLocation` match to a `dispext*` port, and
successful writes. Readback failures are normal at roughly one in eight and prove
nothing; only a write failure is a real fault.

## Step 2: is the camera seeing anything?

```
open --stdout /tmp/s.log --stderr /tmp/s.log dist/BetterScreen.app --args --snapshot
```

Read the ASCII preview. Uniformity below about 5% means an obstructed lens; a
detailed scene with tens of percent of variation means the optical path is fine and
a flat *reading* must be explained elsewhere. Cameras that deliver no frames within
the timeout are unusable — the built-in FaceTime camera reports nothing while the
lid is closed, and only the external webcam has supported `exposureMode = .locked`.

## Step 3: does exposure lock actually hold?

```
open --stdout /tmp/probe.log --stderr /tmp/probe.log dist/BetterScreen.app --args --watch-light
```

Sixty seconds, locked for the first half and autoexposure for the second as a
control. Ask the user to cover the lens once in each half. Verified good result:
about 0.9 stops of dip under lock against roughly 0.04 unlocked. Equal response in
both halves would mean the lock is cosmetic and the UVC firmware never stopped
metering — a possibility no API call can rule out, since the property reads back as
locked either way.

## Step 4: does ambient light reach the display?

Run the real app, then change the light. Only this step proves the product works.

Success looks like paired ambient and control lines:

```
[ambient] light=0.92× (-0.11 stops) raw=0.2685 gain=1.0000 locked=y reliable=y
[control] DELL P2723QE: 75% -> 72% (-0.34 stops)
```

Returning to the original lighting must bring brightness back to the anchor.

## Interpreting the numbers

- `gain` should sit at `1.0000` and return near it after an excursion. A value
  orders of magnitude away means the re-range bookkeeping has drifted, and every
  `stops` figure downstream is fiction. It once reached `0.0059`, reporting a
  normally lit room as `+7.29 stops` / `156×`.
- Roughly 0.1 stops of residual error per re-range is currently expected. Whole
  stops are not.
- `reliable=n` readings must be discarded by the controller, not acted on.
- A brightness change with no preceding ambient change is not the loop working. It
  is a bug — most likely the curve anchoring somewhere other than the display's
  current level.

## Coordinating physical changes with the user

This is the main practical difficulty, and three attempts were lost to it.

- Never rely on the user acting inside a narrow window. Give a wide one, or leave
  the app running indefinitely and let them report when finished.
- State expected direction and magnitude up front, so a null result is
  distinguishable from a mistimed one.
- Prefer stimuli that stay inside the camera's range: room lights on and off, or a
  hand held at a distance. A palm sealed over the lens is *below the sensor floor*
  and is a robustness test, not a tracking test — correct behaviour there is for
  brightness to hold, not move.
- Triggering the re-anchor path needs about 25 seconds of *continuous* saturation,
  since two re-range attempts must fail eight seconds apart. Two brief covers will
  not do it.

## Reporting

Quote the log lines. If a claim cannot be tied to a line of output or a hardware
read, say it is unverified — including when the user believes it worked. Two
"working" results have turned out to be bugs on inspection: a first-run anchor jump
mistaken for light tracking, and a verdict that passed because an error path
returned a default that happened to satisfy the comparison.
