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
    let controller = AudioProcessController()

    /// Levels are keyed by bundle ID, not PID, so a relaunched app keeps its level.
    private var levels: [String: Float]
    @ObservationIgnored private var taps: [AudioObjectID: ProcessTap] = [:]

    private static let levelsKey = "processLevels"

    init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.levelsKey) as? [String: Double] ?? [:]
        self.levels = stored.mapValues { Float($0) }
    }

    func start() {
        controller.onRefresh = { [weak self] in self?.pruneStaleTaps() }
        controller.start()
    }

    var processes: [AudioProcess] { controller.processes }

    /// Bundle ID when there is one so levels survive relaunch; PID otherwise,
    /// which still lets command-line audio sources be controlled this session.
    private func key(for process: AudioProcess) -> String {
        process.bundleID ?? "pid:\(process.pid)"
    }

    func level(for process: AudioProcess) -> Float {
        levels[key(for: process)] ?? 1.0
    }

    /// Any error surfaced by the tap backing this process, for display in the UI.
    func error(for process: AudioProcess) -> String? {
        taps[process.id]?.errorMessage
    }

    func setLevel(_ value: Float, for process: AudioProcess) {
        let clamped = max(0, min(value, 1.0))
        levels[key(for: process)] = clamped
        UserDefaults.standard.set(levels.mapValues { Double($0) }, forKey: Self.levelsKey)

        // A tap is only worth its cost while the app is actually attenuated.
        // At 100% we tear it down so the app returns to the untouched hardware path.
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
        }
    }

    /// Drop taps for processes that have stopped producing audio or exited.
    func pruneStaleTaps() {
        let live = Set(controller.processes.map(\.id))
        for (id, tap) in taps where !live.contains(id) {
            tap.invalidate()
            taps.removeValue(forKey: id)
        }
    }

    func reset(_ process: AudioProcess) {
        setLevel(1.0, for: process)
    }

    func shutdown() {
        controller.stop()
        taps.values.forEach { $0.invalidate() }
        taps.removeAll()
    }
}
