# 001 — Ring light / screen-as-lamp: technical feasibility

Status: research complete, nothing built.
Date: 2026-09-16.
Machine everything below was measured on: MacBook Air (T8112 / M2), macOS 27.0 build 26A428,
Xcode 27.0, arm64. Logical main display 1710x1112 @2x, built-in, notched.

Every claim is tagged **VERIFIED** (I read the real header/binary, or ran code and am quoting
its output) or **UNVERIFIED** (reasoned, or from memory, or blocked by something I would not do
from a background agent). Where a test was possible I ran it. Raw probe programs live in the
session scratchpad, not in this repo.

**Headline:** the ring light is practical, and the most robust version of it does **not** need
the brightness API at all. See §3.

---

## 1. Reading ambient light

### 1.1 Does a third-party app get the ALS on Apple Silicon / macOS 27?

**Yes. VERIFIED — I read it.** No root, no entitlement, not sandboxed (this app is already
`ENABLE_APP_SANDBOX = NO`, verified in `glance.xcodeproj/project.pbxproj:280,316`).

The mechanism is `IOHIDEventSystemClient`, not IOKit service matching, and not
`AppleLMUController`.

**The Intel-era story is dead. VERIFIED.** `ioreg -c AppleLMUController` returns nothing on this
machine. There is no `AppleLMUController`, no `AppleSMCLMU`. Anything written before ~2020 that
tells you to open that service is describing hardware that no longer exists here.

**What is actually there.** Two nodes in the IORegistry, both hanging off the AOP (Always-On
Processor) / SPU sensor bus:

```
+-o AOPEndpoint6  <class RTBuddyEndpointService>
  +-o AppleSPU@1000000f  <class AppleSPU>
    +-o als  <class AppleSPUHIDInterface, id 0x100000663>
      +-o AppleSPUHIDDevice
          "Product"           = "als"
          "Transport"         = "SPU"
          "Built-In"          = Yes
          "DeviceUsagePairs"  = ({"DeviceUsagePage"=65280, "DeviceUsage"=4})
          "PrimaryUsagePage"  = 65280      // 0xff00, Apple vendor page
          "PrimaryUsage"      = 4
          "IOUserClientClass" = "IOHIDLibUserClient"
          "ReportInterval"    = 8000       // microseconds -> 125 Hz
          "MaxInputReportSize"= 122
```

There is a sibling `als-temp` (usage 5, `VendorID = 1452`) which is the sensor's temperature
channel, not a light reading.

The driver class is **`AppleSPUVD6286`** (verified via `ioreg -c AppleSPUVD6286`, whose `Product`
is `"als"`, `PrimaryUsagePage` 65280, `PrimaryUsage` 4). VD6286 is an STMicroelectronics ambient
light / colour sensor part. **UNVERIFIED** that the part number means what I think it means —
that is from memory, not from a datasheet I read. What *is* verified is that the ALS is a
discrete HID device on the sensor coprocessor, entirely separate from the camera.

### 1.2 The exact constants

| Thing | Value |
|---|---|
| Framework to `dlopen` | `/System/Library/Frameworks/IOKit.framework/IOKit` |
| Matching dictionary | `{"PrimaryUsagePage": 0xff00, "PrimaryUsage": 4}` |
| Client | `IOHIDEventSystemClientCreate(kCFAllocatorDefault)` |
| Set matching | `IOHIDEventSystemClientSetMatching(client, dict)` |
| Enumerate | `IOHIDEventSystemClientCopyServices(client)` |
| Poll | `IOHIDServiceClientCopyEvent(svc, 12 /* kIOHIDEventTypeAmbientLightSensor */, 0, 0)` |
| Field base | `12 << 16` = `786432` |
| Read | `IOHIDEventGetFloatValue(event, field)` / `IOHIDEventGetIntegerValue` |

All of those symbols are exported from IOKit on this machine — **VERIFIED**, `dyld_info -exports`
lists `_IOHIDEventSystemClientCreate`, `_IOHIDEventSystemClientSetMatching`,
`_IOHIDEventSystemClientCopyServices` and the rest.

They are **all private**. None appear in any public SDK header. `IOKit/hid/IOHIDEventSystemClient.h`
is not shipped. So this is the same risk class as SkyLight: `dlopen` + `dlsym` + hand-declared
`@convention(c)` typedefs.

### 1.3 What the sensor actually returns here — VERIFIED, ran it

Matched exactly 1 service. Ten samples, 300 ms apart, room lighting unchanged:

```
t0 lvl=0.000 ch0=11.0 ch1=7.0 ch2=6.0 ch3=2.0 f7=0.2448
t1 lvl=0.000 ch0=11.0 ch1=7.0 ch2=6.0 ch3=2.0 f7=0.2463
t3 lvl=0.000 ch0=11.0 ch1=7.0 ch2=7.0 ch3=2.0 f7=0.2266
t5 lvl=0.000 ch0=11.0 ch1=7.0 ch2=7.0 ch3=3.0 f7=0.2409
t9 lvl=0.000 ch0=11.0 ch1=7.0 ch2=6.0 ch3=2.0 f7=0.2436
```

Two things matter here, and they are both bad news for the "just read lux" plan:

1. **Field 0 — the one every blog post calls "the lux value" — reads 0.0.** It is not populated
   on this hardware. If we had shipped the standard snippet we would have shipped a constant zero.
2. The live data is in the **raw channels** (fields 1–4) and in field 7 (a float around 0.24 that
   jitters frame to frame). Those are **uncalibrated**. I have no mapping from `ch0=11` to lux,
   and no way to get one without a reference light meter. **UNVERIFIED** what field 7 is; the
   IOHIDEventTypes layout for this event (`ColorSpace`, `ColorComponent0..2`) is from memory.

So the honest summary is: **the ALS is readable, but it hands you an uncalibrated relative number,
not lux.** Usable as "dark vs. dim vs. bright" after we calibrate it ourselves against known
conditions. Not usable as a physical unit.

### 1.4 Where the sensor is, physically

**VERIFIED:** it is a separate HID device from the camera, on a different bus (SPU/AOP), with its
own driver. Covering the camera lens cannot suppress it unless the same piece of tape happens to
cover the ALS aperture too.

**UNVERIFIED:** the exact millimetre location. I could not confirm from a teardown from here. On
notched MacBooks the ALS aperture is generally described as sitting in the notch region beside
the camera cluster, but I am not going to assert that as measured fact.

The user's observation — covering the camera did not change auto-brightness — is **fully
consistent** with the verified part: different sensor, different bus, different driver.

### 1.5 Recommendation: **No. Do not take the ALS dependency.**

Reasons, in order of weight:

1. **It does not give us what we wanted.** The lux field is zero on this exact machine. We would
   be shipping a private-API dependency for a number we then have to calibrate ourselves against
   the camera anyway.
2. **The one case it wins is narrower than it looks.** The argument was "at scan start the camera
   has not auto-exposed yet, so its luma is unreliable, but the ALS is instant." That is true —
   but see §4: the built-in camera on this Mac reports **no exposure controls at all** and runs a
   fixed 30 fps continuous auto-exposure we cannot touch. The first two or three frames settle in
   under ~100 ms, which is inside the notch-overlay animation. We do not have a real cold-start
   gap to fill.
3. **Second private framework, second thing to break.** SkyLight is load-bearing — without it the
   app does not work on the lock screen, so the risk is justified. An ALS read that only nudges a
   glow brightness is not.

Use mean luma from the camera frames the app already receives. If a cold-start prior turns out to
be genuinely needed later, add the ALS then, behind the same `nil`-on-failure pattern
`NotchSkyLight` already uses.

---

## 2. Controlling display brightness

### 2.1 Which APIs exist — VERIFIED by `dyld_info -exports` on this machine

**`DisplayServices` (`/System/Library/PrivateFrameworks/DisplayServices.framework`) — alive, full set:**

```
_DisplayServicesGetBrightness            _DisplayServicesSetBrightness
_DisplayServicesSetBrightnessWithType    _DisplayServicesSetBrightnessSmooth
_DisplayServicesGetLinearBrightness      _DisplayServicesSetLinearBrightness
_DisplayServicesCanChangeBrightness      _DisplayServicesNeedsBrightnessSmoothing
_DisplayServicesRegisterForBrightnessChangeNotifications
_DisplayServicesHasAmbientLightCompensation
_DisplayServicesAmbientLightCompensationEnabled
_DisplayServicesEnableAmbientLightCompensation
```

**`CoreDisplay` (a *public* framework path, but these symbols are not in any header) — alive:**

```
_CoreDisplay_Display_GetUserBrightness        _CoreDisplay_Display_SetUserBrightness
_CoreDisplay_Display_GetLinearBrightness      _CoreDisplay_Display_SetLinearBrightness
_CoreDisplay_Display_SetDynamicLinearBrightness
_CoreDisplay_Display_SetAutoBrightnessIsEnabled
_CoreDisplay_Display_GetAmbientBrightnessInNits
_CoreDisplay_Display_GetDisplayBrightnessInNits
_CoreDisplay_DisplayPtr_SetLuminanceLimit
```

**IOKit `IODisplaySetFloatParameter` / `IODisplayGetFloatParameter` — the symbols still exist**
(verified in IOKit's export list), **but this is the dead one on Apple Silicon. UNVERIFIED but
high confidence**: the `kIODisplayBrightnessKey` path depended on an `IODisplayConnect` service
that internal panels no longer publish on AS. I did not run it. Do not build on it.

### 2.2 Does it actually work? — VERIFIED, ran it, restored afterward

```
ALSCompEnabled rc=0 enabled=1          <- auto-brightness is ON on this machine
orig=0.594299
Set(0.300000) rc=0
after set, Get=0.300000  (moved=1)
  t+0.5s 0.300000
  t+1.0s 0.300000
  t+1.5s 0.300000
  t+2.0s 0.300000
  t+2.5s 0.300000
  t+3.0s 0.300000
restored to 0.594299
```

And a full sweep, each level held 1 s, read back to confirm:

```
slider 0.05 (read 0.050)   slider 0.20 (read 0.200)   slider 0.40 (read 0.400)
slider 0.60 (read 0.600)   slider 0.80 (read 0.800)   slider 1.00 (read 1.000)
restored 0.59429866
```

So, verified on real hardware, from an ordinary non-root user process with no special entitlement:

- `DisplayServicesGetBrightness(CGMainDisplayID(), &float)` → `rc = 0`, sane value.
- `DisplayServicesSetBrightness(display, 0.0...1.0)` → `rc = 0`, takes effect immediately,
  exact on read-back, across the full range.
- `DisplayServicesCanChangeBrightness(display)` → `1`.
- `DisplayServicesHasAmbientLightCompensation(display)` → `1`.
- `DisplayServicesAmbientLightCompensationEnabled(display, &bool)` → `rc = 0`, `enabled = 1`.
  **Note the signature**: it takes a `bool*` out-param. Calling it as `int f(CGDirectDisplayID)`
  segfaults — I did that first and got SIGSEGV. Getting a private signature wrong crashes, it
  does not fail gracefully.

### 2.3 Does auto-brightness fight us?

**No, not on the timescale that matters. VERIFIED.** Auto-brightness was *enabled* for the whole
test above, and the forced value sat unmoved at exactly 0.300000 for three seconds. A face scan
is 1–3 s. We do not need to suspend anything.

We *could* suspend it (`DisplayServicesEnableAmbientLightCompensation`, or
`CoreDisplay_Display_SetAutoBrightnessIsEnabled`) — **recommendation: don't.** It is a persistent
user setting. If the app crashes mid-scan we have silently turned off the user's auto-brightness
and there is no cleanup path from a dead process. Forcing a value is transient; flipping a
preference is not.

**UNVERIFIED:** whether macOS restores the user's slider on its own after a large ambient change
if we forced a value and then crashed. Mitigation regardless: persist the pre-scan brightness to
`UserDefaults` before touching it and restore on next launch if a "glow in progress" flag is set.

### 2.4 `DisplayServicesSetBrightnessSmooth` — do not use

**VERIFIED misbehaviour.** I called `SetBrightnessSmooth(display, 0.55)` while brightness was at
0.30. `rc = 0`, but 1.2 s later the display read **0.850000**. That is neither the value I asked
for nor the value it started at. The signature is not `(CGDirectDisplayID, float target)`.

Do our own ramp with a `CADisplayLink`/timer and repeated `DisplayServicesSetBrightness` calls.
We want frame-accurate control for §6 modulation anyway.

### 2.5 Does it work while the screen is LOCKED?

**UNVERIFIED. This is the single biggest open question in the whole document**, because the lock
screen is the only moment the feature exists for.

I would not lock this machine from a background agent. What is known:

- The test process was an `.accessory` / non-GUI process in the user's session and it worked —
  so foreground/active-app status is not required. VERIFIED.
- `IOConsoleLocked = No` was in the IORegistry root at test time, i.e. everything above was
  measured unlocked. VERIFIED (read it out of `ioreg`).
- The app already holds a live SkyLight connection on the lock screen
  (`NotchSkyLight.swift`), so the process does keep a working window-server connection there.
  Brightness goes through the same window-server/CoreDisplay path. Plausible, not proven.

**Test to run in Face Lab, first thing, before any of this is built:**
a debug button that schedules `DisplayServicesSetBrightness(0.1)` → wait 2 s →
`SetBrightness(1.0)` → wait 2 s → restore, 10 seconds after the button is pressed; then lock the
screen and watch. Log every `rc`. If `rc != 0` or nothing visibly changes on the lock screen,
the whole brightness half of this feature is dead and §3 becomes the only route.

### 2.6 Risk assessment

| API | Break likelihood on an OS bump | Failure mode |
|---|---|---|
| `DisplayServicesGet/SetBrightness` | **Low.** Long-lived, widely used by Apple's own Displays pane and by every third-party brightness utility. | Symbol missing → `dlsym` returns NULL → we detect and skip. Silent no-op if it stays but stops working. |
| Calling it with a wrong signature | n/a | **Crash (SIGSEGV).** Observed. |
| `CoreDisplay_Display_*` | Low-medium. | Same. |
| `IODisplaySetFloatParameter` | Already effectively dead on AS. | Returns an error, no-op. |
| ALS via `IOHIDEventSystemClient` | Medium. Event field layout is undocumented and already differs from the published lore (field 0 is zero here). | Returns garbage or zeros — **silently wrong**, which is worse than crashing. |

Mitigation pattern, same as `NotchSkyLight`: one loader type, `init?`, `nil` on any missing
symbol, every caller treats `nil` as "feature unavailable" rather than a failure. And add what
SkyLight *doesn't* do — **check the return codes** (`rc == 0`) and read back the value to confirm
the write landed. That is §3.3 of `CLAUDE.md` all over again; do not repeat the mistake.

---

## 3. Alternative: light without the brightness API — **this is the good answer**

### 3.1 The baseline overlay

A full-screen opaque white overlay at the *current* brightness, drawn in the existing
SkyLight-delegated lock-screen window. **UNVERIFIED** how many lux that puts on a face at 50 cm —
I have no light meter. Qualitatively it is the Snapchat effect and it obviously works; the
uncertainty is only "how much", and that is a Face Lab measurement, not a research question.

What this buys with certainty: on a locked Mac the display is usually **dimmed or asleep**, so
going from "dim lock screen" to "full-screen white at current brightness" is already a large
change with zero private API.

### 3.2 EDR — **VERIFIED, and it is worth roughly a full stop**

`NSScreen` exposes EDR headroom publicly:

```
maximumExtendedDynamicRangeColorComponentValue           (current headroom)
maximumPotentialExtendedDynamicRangeColorComponentValue  (ceiling)
maximumReferenceExtendedDynamicRangeColorComponentValue
```

Measured on the built-in display, **VERIFIED, ran it**:

| condition | current headroom | potential |
|---|---|---|
| no EDR content on screen | **1.000** | 2.000 |
| EDR `CAMetalLayer` on screen but no frame ever presented | **1.000** | 2.000 |
| EDR layer presenting frames with clear colour 2.0 | **1.094** | 2.000 |
| EDR layer presenting frames with clear colour 4.0 | **1.994** | 2.000 |

And with the 4.0-demand layer running, swept across the brightness slider:

```
slider 0.05 -> maxEDR 1.994      slider 0.50 -> maxEDR 1.994
slider 0.15 -> maxEDR 1.994      slider 0.75 -> maxEDR 1.994
slider 0.30 -> maxEDR 1.994      slider 1.00 -> maxEDR 1.994
```

Three conclusions, all measured:

1. **We get ~2.0x nominal SDR white out of this panel, on top of whatever the slider is.**
   Including at slider = 1.0. That is about +1 stop of fill light **with no private API and no
   brightness API at all.**
2. **Headroom is demand-driven and ramps.** It is 1.0 until real EDR frames are presented, and it
   climbs toward the ceiling over roughly a second or two. So a glow that needs full output must
   start its EDR demand ~1–2 s before it needs the light, or accept a ramp-in. This directly
   constrains §6 modulation timing — see the caveat below.
3. **A SwiftUI `Color.white` cannot do this.** Exceeding 1.0 requires a `CAMetalLayer` with
   `wantsExtendedDynamicRangeContent = true`, an extended-range pixel format (`.rgba16Float`), an
   extended-linear colour space, and presented drawables. That is a real but small amount of
   Metal.

Test program used, in case it needs re-running: `CAMetalLayer`, `pixelFormat = .rgba16Float`,
`colorspace = extendedLinearSRGB`, `wantsExtendedDynamicRangeContent = true`, render pass with
`MTLClearColor(4,4,4,1)`, `present(drawable)` each pump iteration.

**UNVERIFIED and important:** whether an EDR `CAMetalLayer` still gets headroom **inside a
SkyLight-delegated window on the lock screen**. The window is in a hand-made space at absolute
level 400; EDR arbitration is a window-server function and might behave differently there. This
is the second must-run Face Lab test.

**UNVERIFIED:** whether sustained ~2x-white full-screen output triggers thermal or
`CBBrightDotMitigation`-style luminance clamping. (`_$sSo21CBBrightDotMitigationC…` is a real
symbol in CoreBrightness — verified it exists — but I have no idea when it engages.) A 2 s scan
is probably too short to matter.

### 3.3 Recommendation

**Build the light as an EDR overlay first, and treat `DisplayServicesSetBrightness` as an
optional amplifier layered on top.**

Ranked by (light gained) / (fragility):

1. Full-screen white overlay — free, public, cannot break.
2. EDR to ~2.0x — public API, measured, cannot break, ~+1 stop.
3. `DisplayServicesSetBrightness` → 1.0 — private, verified working today, gains whatever the gap
   is between the user's current slider and 100%. On a dark-room lock screen that gap is usually
   large, so it is worth having; but it is the part that should degrade gracefully to "off".

That ordering also means the feature ships even if §2.5 comes back negative.

---

## 4. The feedback loop — and the bad news

### 4.1 What AVFoundation gives us on macOS

Read straight out of
`MacOSX27.0.sdk/…/AVFoundation.framework/Headers/AVCaptureDevice.h` on this machine. **VERIFIED —
these are the actual availability annotations in the shipping SDK:**

| API | macOS? |
|---|---|
| `isExposureModeSupported:` / `exposureMode` | **available** (no annotation) |
| `AVCaptureExposureModeCustom` (the enum case) | available, `macos(10.15)` |
| `setExposureModeCustomWithDuration:ISO:completionHandler:` | **`API_UNAVAILABLE(macos)`** |
| `setExposureModeCustom(lensAperture:duration:iso:…)` | **`API_UNAVAILABLE(macos)`** |
| `activeMaxExposureDuration` | **`API_UNAVAILABLE(macos)`** |
| `ISO`, `exposureDuration`, `lensAperture` (read-only) | **`API_UNAVAILABLE(macos)`** |
| `exposureTargetBias` + `setExposureTargetBias:` | **`API_UNAVAILABLE(macos)`** |
| `exposureTargetOffset` | **`API_UNAVAILABLE(macos)`** |
| `AVCaptureDeviceFormat.minISO` / `.maxISO` | **`API_UNAVAILABLE(macos)`** |
| `AVCaptureDeviceFormat.min/maxExposureDuration` | **`API_UNAVAILABLE(macos)`** |
| `AVCaptureDeviceFormat.isVideoBinned` | **`API_UNAVAILABLE(macos)`** |
| `isLowLightBoostSupported` | **`API_UNAVAILABLE(macos)`** |
| `isAdjustingExposure` | available |
| `exposurePointOfInterest` / `…Supported` | available |
| `exposureRectOfInterest` / `…Supported` | available, **`macos(26.0)`** — new |
| `whiteBalanceMode` / `isWhiteBalanceModeSupported:` | available |
| `activeVideoMinFrameDuration` / `…Max…` | available |

Note the amusing trap: `AVCaptureExposureModeCustom` is declared available on macOS, but the only
two methods that can put a device into it are `API_UNAVAILABLE(macos)`. Custom exposure is
reachable in the type system and unreachable in practice.

Also note `isVideoBinned` is unavailable on macOS — so `CLAUDE.md` §3.4's claim that
`selectHighestResolutionFormat` hurts because it defeats pixel binning **cannot be checked from
AVFoundation on this platform.** It may still be true; we just cannot query it. Downgrade that
claim to unmeasured.

### 4.2 What the actual camera reports — VERIFIED, ran it

Discovery session, `authorizationStatus = 3` (authorized), no session running:

```
device: FaceTime HD Camera  model=FaceTime HD Camera
  exposure supported: locked=false auto=false cont=false custom=false
  current exposureMode=0  adjusting=false
  exposurePointOfInterestSupported=false
  exposureRectOfInterestSupported=false
  wb supported: locked=false cont=false
  activeVideoMinFrameDuration=0.0333s (30fps)  max=0.0667s (15fps)
  formats: 1920x1080, 1280x720, 1080x1920, 1760x1328, 640x480, 1328x1760, 1552x1552
           all 420v, all fps=15-30
```

The Continuity Camera (`iPhone17,1`) and Desk View report exactly the same: everything false.

**So: on this Mac we cannot lock exposure, cannot lock white balance, cannot bias exposure,
cannot set an exposure ROI, cannot clamp ISO, cannot clamp shutter.** Not "it's private" — the
device reports no support for any of it. Every mitigation in the original plan is unavailable.

**Caveat, stated honestly:** I measured this with no `AVCaptureSession` running and without
`lockForConfiguration()`. It is conceivable — **UNVERIFIED** — that these report differently once
a session is live. Third Face Lab test: log the same six booleans from inside `CameraManager`
after `session.startRunning()`. I would not bet on it changing.

Side note worth recording: `selectHighestResolutionFormat` currently picks **1552x1552** (2.41 MP),
not 1920x1080 (2.07 MP), because it maximises pixel count. A square format for face unlock is
defensible, but it is almost certainly not what whoever wrote that function intended.

### 4.3 So how do we avoid the oscillation?

Since we cannot lock the camera, the loop has to be made stable by construction:

1. **Open-loop, not closed-loop.** Do not run a controller that reads brightness and adjusts the
   glow. Pick the glow level **once**, from the pre-glow frames, then hold it for the scan. No
   loop, no oscillation. This is the whole fix and it is nearly free.
2. **Ramp, don't step.** A step change makes AE hunt visibly. Ramp the glow over ~300–500 ms;
   AE tracks a ramp smoothly.
3. **Discard the settling frames.** `isAdjustingExposure` *is* available on macOS (verified
   above). Gate recognition and liveness frames on `!device.isAdjustingExposure` after a glow
   change. **UNVERIFIED** whether this property actually toggles on a device that reports no
   exposure mode support — test it, it costs nothing.
4. **For §6 modulation, measure differences, not absolutes.** AE normalises the *global* mean. It
   cannot normalise away a *spatial* redistribution of highlights across the face. Sweeping the
   bright region left-to-right at constant total screen luminance keeps global brightness roughly
   constant, which starves AE of anything to react to, while still moving the specular highlight
   across the nose. **This is the design that survives having no exposure lock** — and it is
   strictly better anti-spoofing than intensity modulation anyway.
5. **Cross-check with `CoreDisplay_Display_GetDisplayBrightnessInNits`** if we want to know what
   the panel is actually emitting during a ramp. Symbol exists (verified); I did not call it.

---

## 5. The glare conflict

### 5.1 What the cue actually does — read from source

`glance/Liveness/GlareCueExtractor.swift` rasterises the native-resolution face crop and counts
pixels that are simultaneously:

- `luma >= 235` (`specularLumaFloor`), luma being `0.299R + 0.587G + 0.114B`, and
- near-neutral: `|Cb - 128| <= 10` and `|Cr - 128| <= 10` (`specularChromaTolerance`).

It returns `specularFraction` (that count / total pixels) and `specularClusterRatio` (the densest
cell's share of those pixels on an 8x8 grid).

`glance/Liveness/LivenessCues.swift:401-410` turns that into a reading:

```swift
let fractionScore = ramp(glare.specularFraction, floor: 0.01, ceiling: 0.08)
let clusterFactor = ramp(glare.specularClusterRatio, floor: 0.3, ceiling: 1.0)
let level = fractionScore * (0.3 + 0.7 * clusterFactor)
let confidence = ramp(Float(glare.cropPixelWidth), floor: 50, ceiling: 130)
```

Fire threshold: `glossLevel = 0.04`, `glossFrames = 3` — and because it is a **deny** cue,
`LivenessEvaluator.currentDecision()` returns `.denied(by: .glossGlare)` **in every mode,
overriding any confirmation already reached**. Three frames is all it takes.

### 5.2 Why the glow will trip it

A ~2x-white full-screen panel 50 cm from a face is a large, neutral-coloured, *spatially
coherent* light source. That is the textbook recipe for exactly what this cue is built to detect:
a big low-chroma near-saturated blob. Forehead and nose-bridge will clip to near-255 and be
near-neutral because the illuminant is white.

`fractionScore` reaching 0.08 (8% of face pixels saturated) is very plausible at 2x white;
`clusterFactor` will be high because the highlight is one contiguous region on the forehead. That
lands `level` near its ceiling, far above 0.04. **It will fire, within three frames.** The app
would reject its own user with "Screen glare detected — this looks like a photo on a display."

This is **UNVERIFIED** in the sense that I have not measured `specularFraction` under a real glow
— that is a Face Lab measurement and it should be the very first thing done. But the cue's
thresholds and the physics both point the same way, and it should be assumed true until measured
otherwise.

### 5.3 The fix: make the cue measure the *residual*, not the total

Naively suppressing `glossGlare` while the glow is on opens a hole: an attacker holds a phone up,
the glow is on, the cue is off, `deviceDetected` is the only deny cue left and it fails whenever
the bezel is out of frame. That is the printed-photo bug again with extra steps. Do not do that.

The honest asymmetry is: **we know exactly what our light is doing and when.** An attacker's
screen glare is uncorrelated with our modulation. Ours is, by construction, perfectly correlated.
So:

**Change the deny cue's input from `specularFraction` to the part of `specularFraction` our own
light does not explain.**

Concretely, with an A/B modulated glow (the same mechanism §6 needs anyway):

1. Drive the glow as an alternating pattern with a known phase — simplest useful version: the
   bright region alternates between the **left half** and the **right half** of the screen at
   ~4 Hz, total emitted luminance held constant.
2. Tag every `LivenessFrame` with the glow phase that was on screen when it was captured. The
   overlay renderer knows this exactly; it is a field on the frame, not an inference.
3. Extend `GlareSample` with a **left/right split** of the specular pixels — the 8x8 grid in
   `GlareCueExtractor` already computes everything needed; it just collapses it to one number.
   Emit `specularCentroidX` (normalised) alongside `specularClusterRatio`. Nearly free: one extra
   accumulator in the existing single pass.
4. Define two quantities over the rolling window:
   - **Explained glare**: the component of specular centroid motion that is in phase with our
     modulation. A real 3D face lit from the left has its highlight on the left of the nose; flip
     the light and the highlight crosses to the right. The centroid tracks our phase.
   - **Unexplained glare**: `specularFraction` averaged over the window, *minus* the part that
     rises and falls with our phase. Glass glare from an attacker's screen is a fixed reflection
     of a fixed room light — it does not move when we flip sides.
5. **Feed only unexplained glare to the deny cue.** `glossLevel = 0.04` keeps its meaning. When
   the glow is off, unexplained glare == total glare and the cue is byte-for-byte what it is
   today — no behaviour change on the existing path, which is the property that makes this safe
   to ship.
6. **Feed explained glare, as a phase-correlated centroid excursion, to a new *confirm* cue.**
   That is §6's active-liveness cue, and it costs almost nothing extra once step 3 and 4 exist.

Why this does not open a hole:

- An attacker's phone still produces a large *static* highlight → unexplained → still denied.
- A printed photo has no specular blob at all, so the deny cue was never the thing catching it;
  the new confirm cue is. A flat print's highlight centroid barely moves with our phase (flat
  Lambertian-ish surface, uniform response), so it fails to confirm.
- Suppression is bounded by *how much light we emitted*, which is a number we chose, not a number
  derived from the image. An attacker cannot inflate our suppression budget.

Implementation shape: `GlareSample` gains `specularCentroidX: Float`; `LivenessFrame` gains
`glowPhase: GlowPhase?`; `LivenessCues.glossGlare(_:)` gains a window parameter so it can subtract
the in-phase component; `GlareCueExtractor` gains one accumulator. `LivenessTuning` gains the new
confirm cue's level/frames. `tools/liveness_selftest.swift` must be extended to drive synthetic
phase-tagged frames, otherwise none of this is testable off-device.

**Ordering constraint, non-negotiable:** the glow must not ship as a user-visible feature until
this is in place, because the intermediate state ("glow on, glare cue as-is") is an app that
rejects its own user, and the tempting hotfix for that ("glow on, glare cue off") is a spoof hole.

---

## What I would build first

**A `ScanLight` overlay that is pure fill light, EDR-based, with no brightness API, off by
default — plus the two Face Lab measurements that decide everything after it.**

Smallest shippable thing:

1. A second lock-screen window beside the notch overlay, delegated through the existing
   `NotchSkyLight` (same space, same level 400), full-screen, click-through, backed by a
   `CAMetalLayer` with `wantsExtendedDynamicRangeContent = true`, `.rgba16Float`,
   `extendedLinearSRGB`. Soft radial/edge falloff, white, alpha-ramped in over ~400 ms.
2. **Open-loop intensity.** Compute mean luma from the last N pre-glow camera frames, map it to
   one of three levels (off / soft / full), latch it for the scan. No controller, no ALS.
3. Start the EDR demand ~1 s before the light is wanted, because headroom ramps (measured).
4. Restore on scan end, on `LockMonitor` unlock, and in a `defer` — plus a `UserDefaults`
   breadcrumb so a crash mid-glow is recoverable on next launch.
5. **Setting default OFF**, with the plain-language note that it lights up the room.
6. Face Lab: a "Glow" toggle and a live readout of `specularFraction`, `specularClusterRatio` and
   the `glossGlare` level, so the §5 conflict is *measured* rather than assumed before anything
   else is built on top.

Explicitly **not** in v1: brightness forcing, the ALS, modulation, the new confirm cue, any change
to `glossGlare`. Each of those is gated on a measurement v1 produces.

The three measurements that unblock everything, in order:

- **Does `glossGlare` fire under the glow, and at what `specularFraction`?** Decides whether §5's
  rework is urgent or merely desirable.
- **Does an EDR `CAMetalLayer` get headroom inside a SkyLight-delegated lock-screen window?**
  Decides whether §3 works where it matters, or whether we are back to §2.
- **Does `DisplayServicesSetBrightness` work on the lock screen?** Decides whether the amplifier
  layer exists at all.

### Genuinely unknown

- Brightness control on the lock screen. Untested, and the feature's value depends on it.
- EDR headroom inside a SkyLight space at level 400. Untested.
- How much light any of this actually puts on a face at 50 cm, in lux. No meter, no number.
  Everything in §3 is ratios, not absolutes.
- Whether `isAdjustingExposure` reports anything useful on a device that claims no exposure mode
  support.
- Whether the camera's exposure booleans change once a session is live (§4.2 caveat).
- What ALS event field 7 is, and what the raw channels mean in physical units.
- Whether sustained ~2x white triggers panel luminance clamping on a 2 s timescale.
- Whether a moving highlight on a real nose is actually separable from a flat print at this
  camera's resolution and noise floor, at 30 fps, in a dark room. The whole §6 keystone rests on
  this and **no number in this document supports it yet.** It is a plausible research direction,
  not a measured capability. Do not describe it as working until Face Lab says it does.
