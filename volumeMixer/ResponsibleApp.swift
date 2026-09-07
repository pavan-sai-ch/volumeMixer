//
//  ResponsibleApp.swift
//  volumeMixer
//
//  Maps an audio-producing process to the app a user would recognise.
//
//  Browsers do not play audio from their main process: Chrome uses
//  "Google Chrome Helper (Renderer)", Safari uses com.apple.WebKit.GPU. Those
//  helpers are not NSRunningApplications, so showing them raw produces rows
//  labelled "helper" and hides the fact that it is really YouTube in Chrome.
//

import AppKit

enum ResponsibleApp {
    /// The app that owns `pid`, or nil if no user-facing app owns it
    /// (system audio daemons such as CoreSpeech resolve to nil).
    static func resolve(pid: pid_t) -> NSRunningApplication? {
        if let direct = NSRunningApplication(processIdentifier: pid), direct.bundleIdentifier != nil {
            return direct
        }
        if let responsible = responsiblePID(for: pid), responsible != pid,
           let app = NSRunningApplication(processIdentifier: responsible),
           app.bundleIdentifier != nil {
            return app
        }
        // Walk the parent chain: a Chrome helper's parent is Chrome itself.
        var current = pid
        for _ in 0..<6 {
            guard let parent = parentPID(of: current), parent > 1 else { break }
            if let app = NSRunningApplication(processIdentifier: parent), app.bundleIdentifier != nil {
                return app
            }
            current = parent
        }
        return nil
    }

    /// `responsibility_get_pid_responsible_for_pid` attributes an XPC-launched
    /// helper back to the app on whose behalf it runs — the only thing that
    /// works for Safari, whose media process is parented to launchd. Resolved
    /// dynamically because it is not in a public header.
    private static let responsibleFn: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), // RTLD_DEFAULT
                                 "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    private static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let fn = responsibleFn else { return nil }
        let result = fn(pid)
        return result > 0 ? result : nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
