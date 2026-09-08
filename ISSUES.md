# volumeMixer — issue log

State as of 2026-09-07. Branch `feat/audio-engine`.

**Everything here is now fixed except one item: whether the attenuation is
audible. That single question needs a human to listen — see item 3.**

Verified means measured or heard, and the evidence is named. Unverified means
written but not yet confirmed working.

---

## 1. Browser audio not recognised — FIXED, verified

**Symptom:** YouTube in a browser never appeared in the mixer.

**Cause:** browsers do not play audio from their main process. Brave/Chrome use
a `Helper (Renderer)` process; Safari uses `com.apple.WebKit.GPU`. Those
helpers are not `NSRunningApplication`s, so they showed up as a nameless
`helper` row rather than as the browser.

**Fix:** `ResponsibleApp.swift` resolves an audio PID to the app that owns it,
in three steps: direct `NSRunningApplication`, then
`responsibility_get_pid_responsible_for_pid` (resolved via `dlsym`; needed for
Safari, whose media process is parented to launchd), then a parent-PID walk
via `sysctl` (enough for Chrome/Brave). `AudioProcess` now represents *one app*
holding *all* the Core Audio process objects it owns, so one slider covers an
app with several noisy tabs.

**Evidence:** with your YouTube tab playing, the mixer reported
`visible=["31248:Brave Browser"]` — previously `helper`.

---

## 2. CoreSpeech and "helper" rows — FIXED, verified

**Cause:** the list was every process with `kAudioProcessPropertyIsRunningOutput
== 1`, which includes system audio daemons. `com.apple.CoreSpeech` reports
running output while producing nothing audible.

**Fix:** a row is shown only if it resolves to a real user-facing app (an
`NSRunningApplication` with a bundle identifier). Daemons resolve to nothing
and are dropped. This is a principled filter, not a hardcoded blocklist.

**Evidence:** same run as above — CoreSpeech no longer listed.

---

## 3. Audio silent below 100% — ROOT CAUSE FOUND, fix built, NOT yet verified by ear

This is the important one. It took four wrong hypotheses to find, so the
eliminated ones are recorded to save repeating them.

**Root cause:** `CATapDescription.muteBehavior` was `.mutedWhenTapped`. Its
header says it mutes the process only *"until the tap is read by another audio
client"*. Our tap is **private** and read by the **same** process that created
it, so that condition never fires — the app kept playing at full volume while
our relay played a second, attenuated copy on top. That is why Brave showed
"no change": you were hearing the original plus a 25% copy summed.

**Fix:** `description.muteBehavior = .muted`, which suppresses the process's
own output unconditionally. Correct here because we always relay.

**Also added — silence fail-safe:** `Mixer.verifyAudioFlowing(for:)`. 1.5s after
a tap activates, if the render callback is running but every sample is zero, the
tap is destroyed and the app returned to 100%. A muted tap delivering silence
is worse than no attenuation, and this can no longer strand an app in silence.

**Hypotheses eliminated, with evidence — do not re-investigate:**

| Hypothesis | Ruled out by |
|---|---|
| Buffer/format mismatch between tap and device | Both sides 48kHz, 2ch, float32, interleaved, 1 buffer, 4096 bytes, non-nil (`diag.swift`) |
| Writing to a private aggregate's output never reaches the speaker | You heard test tone A (440Hz written straight to the aggregate) |
| TCC denying audio capture to the bundled app | Bundled app measured `inputPeak=0.8675`, `error=nil` — real samples arrive, no denial |
| `pruneStaleTaps` destroying its own tap in a loop | Tapped process stayed in the list with `isRunningOutput=1` for the whole test |
| Bug in `ProcessTap.swift` itself | Its real source compiled into a CLI harness relayed correctly: peak `0.1525852` at gain 0.25 |

**Automated verification attempted and rejected.** Two approaches were tried
and neither can answer this:

* A global tap excluding our own process (`h2`) reported the target still at
  `0.65` after `.muted`. **This measurement is invalid** — a tap captures what
  a process *renders*, which does not reflect whether audio reached the
  hardware, so it cannot distinguish the two cases. Do not trust that number.
* `kAudioProcessPropertyIsRunningOutput` stays `1` on a muted process, so it is
  not a mute indicator either.
* `kAudioHardwarePropertyProcessIsAudible` ('pmut') looked promising and is
  what the original README implied, but it is declared in the
  **system-object** property enum and documents "the audio of *the process*" —
  it mutes only the calling process. It cannot silence another app, so it is
  useless here. This rules out the README's suggested approach permanently.

There is no public API that reports the final device mix, so this is not
automatable. It needs one listen.

**What still needs checking:** whether `.muted` actually attenuates audibly. Build and run, play audio in two apps, drag one slider down. Expect
that app quieter, the other untouched. If the attenuated app goes fully
**silent** instead, the mute is engaging but the relay is not reaching your
speaker — check Console for `delivered only silence; restoring direct output`,
which means the fail-safe fired and the tap was getting zeros.

---

## 4. Mixer did not start until the menu was opened — FIXED

`.task` on `MenuBarExtra` content only runs when the menu is *built*, i.e. on
first click, so polling had not begun and the list was empty for a second after
opening. Startup moved to `AppDelegate.applicationDidFinishLaunching` via
`Mixer.shared`.

---

## Diagnostic tooling built (kept, since it will be useful again)

* `VOLUMEMIXER_SELFTEST_PID=<pid>` — on launch, attenuates that app to 25% and
  writes `SELFTEST RESULT callbacks=… inputPeak=… error=…` to stderr. Lets the
  audio path be exercised without dragging a slider. Run the binary directly:
  `VOLUMEMIXER_SELFTEST_PID=$(pgrep -x "Brave Browser" | head -1) \
    "$(...)/volumeMixer.app/Contents/MacOS/volumeMixer"`
* `ProcessTap.inputPeak` / `.callbackCount` — distinguishes "tap delivering
  audio" from "tap delivering digital silence", which are identical by status
  code. Both return `noErr`.
* Standalone probes under the job tmp dir (`probe2`, `diag`, `probe4`, `probe5`,
  `probe6`, `harness`) measure each stage in isolation. `probe6` is the A/B
  tone test that settled the aggregate-output question.

**Cleanup before release:** the `FileHandle.standardError` writes in
`Mixer.debugSelfTest` and `AppDelegate` are crude diagnostics. Convert to
`Logger` or gate behind `#if DEBUG`.

---
## 5. Output device changes not followed — FIXED, verified

`Mixer.startDeviceChangeListener` observes
`kAudioHardwarePropertyDefaultOutputDevice` and rebuilds every live tap around
the new device, preserving each app's gain. Without it, an app attenuated
before switching to headphones stayed bound to the old device.

**Evidence:** with a tap live at 0.25, switching the default output away and
back produced, both times: listener fired → `DEVICE CHANGED — rebuilding 1
tap(s)` → `TAP ACTIVE … gain=0.25`. The app survived both switches.

## 6. Remembered levels never re-applied — FIXED, verified

`reconcileTaps` (formerly `pruneStaleTaps`) now also *creates* taps for apps
that reappear with a stored level below 100%. Previously a level restored from
`UserDefaults` did nothing until the slider was touched. It also rebuilds a tap
when an app's set of audible process objects changes, so a newly playing
browser tab cannot escape the slider.

**Evidence:** two-pass test. Pass 1 attenuated the fixture to 25% and wrote
`processLevels`. Pass 2 relaunched with no self-test and produced
`TAP ACTIVE id=test.volumemixer.toneplayer gain=0.25` unprompted — exactly one
activation in 7s, so the 1s poll is not thrashing.

Levels of exactly 1.0 are no longer persisted, so apps stop accumulating
permanent redundant entries.

## 7. Fail-safe invisible in the UI — FIXED

`MenuBarView` now shows "Can't adjust this app — its audio wasn't readable, so
it was left at 100%" for apps in `silentTaps`, instead of the slider silently
snapping back with no explanation. The flag clears when that app's slider is
next moved.

Also verified: killing a target app while its tap was live pruned cleanly, with
no crash and no repeat activation.

---

## Test fixture

Automated testing needs an audio source the mixer will actually list, and the
app deliberately hides sources with no owning application — which excludes
`afplay`. So there is a minimal signed app bundle, `TonePlayer.app`, playing a
440Hz tone at amplitude 0.35 via `AVAudioEngine` (source in the job tmp dir).
It appears as a normal app, which makes detection, tapping, level restore,
teardown and device switching testable without touching Music or a browser.

Gotchas found the hard way while building these tests:

* **`MSLoopbackDriverDevice` cannot be made the default output.**
  `AudioObjectSetPropertyData` returns `noErr` but the default does not change,
  which silently invalidates any device-switch test built on it. Use a real
  output device and assert the switch took effect before trusting the result.
* **`pkill -f "volumeMixer.app/..."` matches the shell running it** and kills
  its own process. Use `pkill -x volumeMixer`.
* **Prefer removing `~/Library/Preferences/app.pavanchilukala.volumeMixer.plist`
  directly** (read it back with `plutil -p`) over the `defaults` CLI. Three test
  runs containing `defaults delete` timed out; the command itself did return
  exit 0 (`Domain … not found`), so the preferences system was **not** wedged
  and the real cause of those stalls was never isolated. The plist route avoids
  the question.
* **Do not drive Music with AppleScript:** it timed out with `-1712`, most
  likely an automation permission prompt.

---

## Open items / known limitations

1. **Attenuation not yet confirmed audible** — item 3. The only item that needs
   a person, and the only one not verified. Everything else above is verified.
2. **Added latency for attenuated apps**, since their audio takes an extra hop
   through the render callback. Apps at 100% have no tap and are unaffected.
3. **No boost above 100%.** Slider is 0–100%; the engine clamps to 1.0.
4. **Command-line audio sources cannot be controlled.** A row requires an
   owning app, so `afplay` and similar are invisible. Deliberate — it is what
   removes the CoreSpeech and helper noise — but a real limitation.
5. **`Mixer.debugSelfTest` and the `#if DEBUG` stderr writes** are test
   scaffolding. Compiled out of Release, but tidy them before shipping.
