//
//  MenuBarView.swift
//  volumeMixer
//
//  The menu bar panel: one row per audible app, Windows-mixer style.
//

import SwiftUI

struct MenuBarView: View {
    @Bindable var mixer: Mixer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if mixer.processes.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(mixer.processes) { process in
                            ProcessRow(process: process, mixer: mixer)
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
                }
                .frame(maxHeight: 340)
            }

            Divider()
            footer
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Image(systemName: "slider.vertical.3")
            Text("Volume Mixer").font(.headline)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text("No apps playing audio")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Start playback and apps appear here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    private var footer: some View {
        HStack {
            Button("Reset all") {
                for process in mixer.processes { mixer.reset(process) }
            }
            .buttonStyle(.link)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.link)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct ProcessRow: View {
    let process: AudioProcess
    @Bindable var mixer: Mixer

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                icon
                Text(process.name).font(.subheadline).lineLimit(1)
                Spacer()
                Text("\(Int((level * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    mixer.setLevel(level > 0 ? 0 : 1.0, for: process)
                } label: {
                    Image(systemName: level > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .frame(width: 16)
                }
                .buttonStyle(.borderless)
                .help(level > 0 ? "Mute" : "Unmute")

                Slider(
                    value: Binding(
                        get: { Double(level) },
                        set: { mixer.setLevel(Float($0), for: process) }),
                    in: 0...1)
            }

            if mixer.silentTaps.contains(process.id) {
                Text("Can't adjust this app — its audio wasn't readable, so it was left at 100%.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            } else if let error = mixer.error(for: process) {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    private var level: Float { mixer.level(for: process) }

    private var icon: some View {
        Group {
            if let image = process.icon {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: "app.dashed").resizable()
            }
        }
        .frame(width: 18, height: 18)
    }
}
