//
//  Mixer.swift
//  volumeMixer
//
//  Owns one ProcessTap per app the user has moved off 100%, and remembers
//  levels by bundle ID across launches.
//

import CoreAudio
import Foundation
import Observation
import os

private let log = Logger(subsystem: "app.pavanchilukala.volumeMixer", category: "Mixer")

@MainActor
@Observable
final class Mixer {
    /// Single instance shared by the scene and the app delegate.
    static let shared = Mixer()

    let controller = AudioProcessController()

    /// Levels are keyed by bundle ID, not PID, so a relaunched app keeps its level.
    private var levels: [String: Float]
    @ObservationIgnored private var taps: [String: ProcessTap] = [:]
    @ObservationIgnored private var deviceListener: AudioObjectPropertyListenerBlock?

    private static let levelsKey = "processLevels"

    init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.levelsKey) as? [String: Double] ?? [:]
        self.levels = stored.mapValues { Float($0) }
    }

    func start() {
        controller.onRefresh = { [weak self] in self?.reconcileTaps() }
        controller.start()
        startDeviceChangeListener()
    }

    /// Rebuild every live tap around the new default output device. The
    /// aggregate device is bound to whichever output existed when the tap was
    /// created, so without this an attenuated app stays silent after the user
    /// switches to headphones.
    private func startDeviceChangeListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.rebuildActiveTaps() }
        }
        deviceListener = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        if status != noErr {
            log.error("could not observe default output device: \(status)")
        }
    }

    private func rebuildActiveTaps() {
        guard !taps.isEmpty else { return }
        log.notice("default output changed; rebuilding \(self.taps.count) tap(s)")
        #if DEBUG
        FileHandle.standardError.write("DEVICE CHANGED — rebuilding \(taps.count) tap(s)\n".data(using: .utf8)!)
        #endif
        for (id, tap) in taps {
            let process = tap.process
            let gain = tap.gain
            tap.invalidate()
            let fresh = ProcessTap(process: process, gain: gain)
            fresh.activate()
            taps[id] = fresh
        }
    }

    var processes: [AudioProcess] { controller.processes }

    func level(for process: AudioProcess) -> Float {
        levels[process.id] ?? 1.0
    }

    /// Any error surfaced by the tap backing this process, for display in the UI.
    func error(for process: AudioProcess) -> String? {
        taps[process.id]?.errorMessage
    }

    func setLevel(_ value: Float, for process: AudioProcess) {
        let clamped = max(0, min(value, 1.0))
        // 100% is the default, so store nothing for it — otherwise every app
        // that ever played audio accumulates a redundant entry forever.
        if clamped >= 1.0 {
            levels.removeValue(forKey: process.id)
        } else {
            levels[process.id] = clamped
        }
        UserDefaults.standard.set(levels.mapValues { Double($0) }, forKey: Self.levelsKey)

        // A tap is only worth its cost while the app is actually attenuated.
        // At 100% we tear it down so the app returns to the untouched hardware path.
        silentTaps.remove(process.id)

        if clamped >= 1.0 {
            if let tap = taps.removeValue(forKey: process.id) {
                tap.invalidate()
                log.info("released tap for \(process.name, privacy: .public)")
            }
            return
        }

        if let tap = taps[process.id] {
            tap.gain = clamped
        } else {
            let tap = ProcessTap(process: process, gain: clamped)
            tap.activate()
            taps[process.id] = tap
            verifyAudioFlowing(for: process)
        }
    }

    /// A muted tap that delivers no samples would leave the app completely
    /// silent — worse than not attenuating at all. If the render callback is
    /// running but every sample is zero, give the app its audio back.
    private func verifyAudioFlowing(for process: AudioProcess) {
        let id = process.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let tap = self.taps[id] else { return }
            guard tap.callbackCount > 0, tap.inputPeak == 0 else { return }
            log.error("tap for \(id, privacy: .public) delivered only silence; restoring direct output")
            tap.invalidate()
            self.taps.removeValue(forKey: id)
            self.levels[id] = 1.0
            self.silentTaps.insert(id)
        }
    }

    /// Apps where attenuation had to be abandoned because the tap was silent.
    private(set) var silentTaps: Set<String> = []

    /// Keep taps in step with what is audible: drop taps whose app is gone,
    /// and start taps for apps that reappeared with a remembered level below
    /// 100%. Without the second half, a level restored from UserDefaults did
    /// nothing until the slider was touched again.
    func reconcileTaps() {
        let live = Dictionary(uniqueKeysWithValues: controller.processes.map { ($0.id, $0) })

        for (id, tap) in taps where live[id] == nil {
            tap.invalidate()
            taps.removeValue(forKey: id)
        }

        // An app whose set of audible process objects changed (a new browser
        // tab started playing) needs its tap rebuilt, or the new stream is
        // neither muted nor relayed and escapes the slider entirely.
        for (id, process) in live {
            guard let tap = taps[id] else { continue }
            guard tap.process.objectIDs != process.objectIDs else { continue }
            let gain = tap.gain
            tap.invalidate()
            let fresh = ProcessTap(process: process, gain: gain)
            fresh.activate()
            taps[id] = fresh
        }

        for (id, process) in live {
            guard taps[id] == nil else { continue }
            guard !silentTaps.contains(id) else { continue }
            let stored = levels[id] ?? 1.0
            guard stored < 1.0 else { continue }
            let tap = ProcessTap(process: process, gain: stored)
            tap.activate()
            taps[id] = tap
            verifyAudioFlowing(for: process)
        }
    }

    func reset(_ process: AudioProcess) {
        setLevel(1.0, for: process)
    }

    /// Diagnostic: attenuate the given PID and report what the tap delivers.
    /// Driven by VOLUMEMIXER_SELFTEST_PID so the audio path can be exercised
    /// without a human dragging a slider.
    func debugSelfTest(pid: pid_t) {
        refreshNow()
        #if DEBUG
        FileHandle.standardError.write("SELFTEST: visible=\(controller.processes.map { "\($0.pid):\($0.name)" })\n".data(using:.utf8)!)
        #endif
        guard let target = controller.processes.first(where: { $0.pid == pid }) else {
            log.error("selftest: pid \(pid) is not producing audio")
            return
        }
        setLevel(0.25, for: target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, let tap = self.taps[target.id] else {
                log.error("selftest: no tap present after setLevel")
                return
            }
            let msg = "SELFTEST RESULT callbacks=\(tap.callbackCount) inputPeak=\(tap.inputPeak) error=\(tap.errorMessage ?? "nil")\n"
            #if DEBUG
            FileHandle.standardError.write(msg.data(using:.utf8)!)
            #endif
            log.error("\(msg, privacy: .public)")
        }
    }

    func refreshNow() { controller.refresh() }

    func shutdown() {
        if var address = Optional(AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)), let block = deviceListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
            deviceListener = nil
        }
        controller.stop()
        taps.values.forEach { $0.invalidate() }
        taps.removeAll()
    }
}
