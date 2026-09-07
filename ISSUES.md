# volumeMixer — issue log

State as of 2026-09-07. Branch `feat/audio-engine`.

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

**What still needs checking tonight:** whether `.muted` actually attenuates
audibly. Build and run, play audio in two apps, drag one slider down. Expect
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

## Open items / known limitations

1. **Attenuation not yet confirmed audible** — item 3 above. Highest priority.
2. **Output device changes are not followed.** The aggregate is built around
   whatever the default output was when the tap started. Switching output device
   while an app is attenuated needs the app toggled to 100% and back. Fix would
   be a listener on `kAudioHardwarePropertyDefaultOutputDevice` that rebuilds
   live taps.
3. **`silentTaps` is recorded but not surfaced in the UI.** When the fail-safe
   fires, the user sees the slider jump back to 100% with no explanation.
   `MenuBarView` should show a note for apps in that set.
4. **Added latency for attenuated apps**, since their audio takes an extra hop.
   Apps at 100% have no tap at all and are unaffected.
5. **No boost above 100%.** Slider is 0–100%; engine clamps to 1.0.
6. **`kAudioHardwarePropertyProcessIsAudible` is not used.** It exists (`'pmut'`)
   but is a *global settable mute*, not the per-app query the original README
   implied. The right per-app query is `kAudioProcessPropertyIsRunningOutput`,
   which is what the controller uses.
7. **Levels persist by bundle ID** in `UserDefaults` under `processLevels`. An
   app attenuated then quit comes back attenuated, but no tap exists until it
   next produces audio and the level is re-applied — currently that only
   happens when the slider is touched. Worth wiring into `refresh()`.
