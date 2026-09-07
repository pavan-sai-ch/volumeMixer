//
//  AudioProcess.swift
//  volumeMixer
//
//  Model for a single process that is producing audio output.
//

import AppKit
import CoreAudio

/// One audio-producing process, as seen by Core Audio.
struct AudioProcess: Identifiable, Hashable {
    /// Core Audio process object ID — the handle a tap is built from.
    let id: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let name: String
    let icon: NSImage?

    init(id: AudioObjectID, pid: pid_t, bundleID: String?) {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID

        let running = pid > 0 ? NSRunningApplication(processIdentifier: pid) : nil
        self.name = running?.localizedName
            ?? bundleID?.components(separatedBy: ".").last
            ?? "PID \(pid)"
        self.icon = running?.icon
    }

    static func == (lhs: AudioProcess, rhs: AudioProcess) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
