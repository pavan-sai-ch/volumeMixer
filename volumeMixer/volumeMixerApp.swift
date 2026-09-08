//
//  volumeMixerApp.swift
//  volumeMixer
//
//  Created by Pavan Sai Chilukala on 5/6/26.
//

import SwiftUI

/// Startup lives here rather than in a `.task` on the menu content: that
/// content is only built when the menu is opened, so polling would not begin
/// until the first click and the list would be empty for a second after it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        FileHandle.standardError.write("DELEGATE: applicationDidFinishLaunching\n".data(using:.utf8)!)
        #endif
        MainActor.assumeIsolated {
            let mixer = Mixer.shared
            mixer.start()
            if let raw = ProcessInfo.processInfo.environment["VOLUMEMIXER_SELFTEST_PID"],
               let pid = pid_t(raw) {
                mixer.debugSelfTest(pid: pid)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Mixer.shared.shutdown() }
    }
}

@main
struct volumeMixerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(mixer: Mixer.shared)
        } label: {
            Image(systemName: "slider.vertical.3")
        }
        .menuBarExtraStyle(.window)
    }
}
