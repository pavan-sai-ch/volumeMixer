//
//  volumeMixerApp.swift
//  volumeMixer
//
//  Created by Pavan Sai Chilukala on 5/6/26.
//

import SwiftUI

@main
struct volumeMixerApp: App {
    @State private var mixer = Mixer()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(mixer: mixer)
                .task {
                    mixer.start()
                }
        } label: {
            Image(systemName: "slider.vertical.3")
        }
        .menuBarExtraStyle(.window)
    }
}
