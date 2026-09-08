# volumeMixer

**volumeMixer** brings Windows-style per-application volume control to the macOS
menu bar. macOS exposes a single global output level; volumeMixer lets you set a
level per app, so you can drop Chrome to 20% while Spotify stays at 100%.

---

## Why this needs a real audio engine

macOS has no per-process volume property — there is nothing to simply *set*.
Core Audio offers no "set app X to 40%" API. The only route available to a
normal app is:

1. Create a **Core Audio tap** on the target process with mute behavior
   `.mutedWhenTapped`. While the tap is being read, that process's audio no
   longer reaches the output hardware.
2. Receive those samples ourselves, scale them by the chosen gain, and render
   the result to the output device through a **private aggregate device**.

Net effect: that one app plays at the chosen level; every other app is
untouched. At 100% the tap is torn down entirely, so the app returns to the
normal, unmodified hardware path.

---

## Requirements

* macOS **14.2+** (`AudioHardwareCreateProcessTap` is `API_AVAILABLE(macos(14.2))`)
* Xcode 15+
* **App Sandbox must stay off.** The sandbox denies Core Audio process taps.
  `ENABLE_APP_SANDBOX = NO` and the audio-input entitlement are already set in
  the project.

## Building

```bash
git clone https://github.com/pavan-sai-ch/volumeMixer.git
cd volumeMixer
xcodebuild -scheme volumeMixer -configuration Debug build
# or just open volumeMixer.xcodeproj and press Cmd+R
```

The app is an `LSUIElement` agent: it has no Dock icon and no window, only a
menu bar item.

---

## Architecture

| File | Role |
|---|---|
| `AudioProcess.swift` | Value type for one audible process: object ID, PID, bundle ID, display name, icon |
| `AudioProcessController.swift` | Polls `kAudioHardwarePropertyProcessObjectList` (1s) and keeps the processes where `kAudioProcessPropertyIsRunningOutput == 1` |
| `ProcessTap.swift` | The engine: tap + private aggregate device + IOProc. Applies gain with `vDSP_vsmul` on the real-time thread |
| `Mixer.swift` | Owns one `ProcessTap` per attenuated app; persists levels by bundle ID in `UserDefaults` |
| `MenuBarView.swift` | The menu bar panel — one row per app: icon, name, percentage, mute toggle, slider |
| `volumeMixerApp.swift` | `MenuBarExtra` entry point |

Levels are keyed by bundle ID so an app keeps its level across relaunches;
processes with no bundle ID (command-line tools) fall back to a PID key, which
lasts for the session.

---

## Permissions

On macOS 26.5 this was measured to need **no TCC prompt**: tap creation and
sample delivery both succeeded from an unsigned binary with no user approval.
The project still declares `com.apple.security.device.audio-input` and
`NSMicrophoneUsageDescription`, because the app genuinely reads other
processes' audio and the requirement may differ on other macOS versions.

volumeMixer does not record, buffer to disk, or transmit any audio. Samples are
scaled and passed straight back to the output device.

---

## Known limitations

* **Output device changes are not followed.** The aggregate device is built
  around whatever the default output was when the tap started. Switching output
  device while an app is attenuated requires toggling that app back to 100% and
  down again.
* **Adds a small amount of latency** for attenuated apps, since their audio
  takes an extra hop through our render callback. Apps at 100% are unaffected.
* **No boost above 100%.** The slider is 0–100%; the engine clamps to 1.0.
* Per-app levels apply to the process, so an app playing several streams has
  them all scaled together.

---

### Created by Pavan
