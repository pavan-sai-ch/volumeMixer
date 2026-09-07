//
//  AudioProcess.swift
//  volumeMixer
//
//  One row in the mixer: a user-facing app, plus every Core Audio process
//  object currently producing audio on its behalf.
//

import AppKit
import CoreAudio

struct AudioProcess: Identifiable, Hashable {
    /// Bundle ID of the owning app — stable across relaunch and across the
    /// helper processes it spawns, so it is both the row identity and the
    /// key levels are remembered under.
    let id: String
    let name: String
    let icon: NSImage?
    let pid: pid_t

    /// Every audible Core Audio process object belonging to this app. A
    /// browser with two noisy tabs contributes more than one.
    let objectIDs: [AudioObjectID]

    init(app: NSRunningApplication, objectIDs: [AudioObjectID]) {
        self.id = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
        self.name = app.localizedName ?? app.bundleIdentifier ?? "PID \(app.processIdentifier)"
        self.icon = app.icon
        self.pid = app.processIdentifier
        self.objectIDs = objectIDs
    }

    static func == (lhs: AudioProcess, rhs: AudioProcess) -> Bool {
        lhs.id == rhs.id && lhs.objectIDs == rhs.objectIDs
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
