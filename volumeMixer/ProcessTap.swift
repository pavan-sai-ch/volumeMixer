//
//  ProcessTap.swift
//  volumeMixer
//
//  Per-process gain via Core Audio taps.
//
//  How this achieves per-app volume: a tap created with `.muted` stops the
//  process's audio from reaching the hardware entirely. We then re-render
//  those same samples ourselves, scaled by
//  `gain`, through a private aggregate device wrapping the default output.
//  Net effect: that one app plays at our chosen level, everything else is
//  untouched. At gain 1.0 the path is a straight copy.
//

import Accelerate
import CoreAudio
import Foundation
import os

private let log = Logger(subsystem: "app.pavanchilukala.volumeMixer", category: "ProcessTap")

final class ProcessTap {
    let process: AudioProcess

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var running = false

    /// Heap-allocated so the render callback can read it without touching
    /// class state, locks, or the main actor. Written from the UI thread.
    private let gainPointer: UnsafeMutablePointer<Float>

    /// [0] = peak input amplitude seen, [1] = render callback count.
    /// Lets the main thread tell "tap is delivering audio" from "tap is
    /// delivering digital silence", which are indistinguishable by status code.
    private let statsPointer: UnsafeMutablePointer<Float>

    private(set) var errorMessage: String?

    init(process: AudioProcess, gain: Float = 1.0) {
        self.process = process
        self.gainPointer = .allocate(capacity: 1)
        self.gainPointer.initialize(to: gain)
        self.statsPointer = .allocate(capacity: 2)
        self.statsPointer.initialize(repeating: 0, count: 2)
    }

    deinit {
        invalidate()
        gainPointer.deinitialize(count: 1)
        gainPointer.deallocate()
        statsPointer.deinitialize(count: 2)
        statsPointer.deallocate()
    }

    /// Peak input amplitude observed by the render callback since activation.
    var inputPeak: Float { statsPointer[0] }
    /// Number of render callbacks served since activation.
    var callbackCount: Int { Int(statsPointer[1]) }

    var gain: Float {
        get { gainPointer.pointee }
        set { gainPointer.pointee = max(0, min(newValue, 1.0)) }
    }

    // MARK: - Lifecycle

    func activate() {
        guard tapID == kAudioObjectUnknown, !process.objectIDs.isEmpty else { return }

        // One tap covering every audible process the app owns, so a browser
        // with several noisy tabs is controlled by a single slider.
        let description = CATapDescription(stereoMixdownOfProcesses: process.objectIDs)
        description.name = "volumeMixer-\(process.id)"
        description.isPrivate = true
        // `.mutedWhenTapped` mutes only while the tap is "read by another audio
        // client" — a private tap read by this same process never satisfies
        // that, so the app kept playing at full volume alongside our relay.
        // `.muted` suppresses the process's own output unconditionally, which
        // is what we want since we always relay.
        description.muteBehavior = .muted
        let tapUUID = description.uuid.uuidString

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            fail("AudioHardwareCreateProcessTap failed", status)
            return
        }

        guard let outputUID = Self.defaultOutputDeviceUID() else {
            fail("could not read default output device UID", noErr)
            return
        }

        // A private aggregate device is the only way to install an IOProc that
        // sees the tap as an input stream and the real output as its output.
        let aggregateUID = UUID().uuidString
        let description2: [String: Any] = [
            kAudioAggregateDeviceNameKey: "volumeMixer \(process.name)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUUID,
            ]],
        ]

        status = AudioHardwareCreateAggregateDevice(description2 as CFDictionary, &aggregateID)
        guard status == noErr else {
            fail("AudioHardwareCreateAggregateDevice failed", status)
            return
        }

        let gain = gainPointer
        let stats = statsPointer
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
            _, inInputData, _, outOutputData, _ in
            ProcessTap.render(input: inInputData, output: outOutputData, gain: gain.pointee, stats: stats)
        }
        guard status == noErr, ioProcID != nil else {
            fail("AudioDeviceCreateIOProcIDWithBlock failed", status)
            return
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            fail("AudioDeviceStart failed", status)
            return
        }

        running = true
        errorMessage = nil
        log.notice("tap active for \(self.process.name, privacy: .public) pid \(self.process.pid)")
        #if DEBUG
        FileHandle.standardError.write("TAP ACTIVE id=\(process.id) gain=\(gainPointer.pointee)\n".data(using: .utf8)!)
        #endif
    }

    func invalidate() {
        if running, let ioProcID { AudioDeviceStop(aggregateID, ioProcID) }
        running = false
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Render

    /// Real-time thread. No allocation, no locks, no Obj-C.
    private static func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        gain: Float,
        stats: UnsafeMutablePointer<Float>
    ) {
        stats[1] += 1
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        for index in 0..<outList.count {
            let outBuffer = outList[index]
            guard let destination = outBuffer.mData else { continue }

            guard index < inList.count, let source = inList[index].mData else {
                // No matching input this cycle — emit silence rather than stale memory.
                memset(destination, 0, Int(outBuffer.mDataByteSize))
                continue
            }

            let byteCount = min(inList[index].mDataByteSize, outBuffer.mDataByteSize)

            var peak: Float = 0
            vDSP_maxmgv(source.assumingMemoryBound(to: Float.self), 1, &peak,
                        vDSP_Length(Int(byteCount) / MemoryLayout<Float>.size))
            if peak > stats[0] { stats[0] = peak }

            if gain == 1.0 {
                memcpy(destination, source, Int(byteCount))
            } else {
                let sampleCount = vDSP_Length(Int(byteCount) / MemoryLayout<Float>.size)
                var scale = gain
                vDSP_vsmul(
                    source.assumingMemoryBound(to: Float.self), 1,
                    &scale,
                    destination.assumingMemoryBound(to: Float.self), 1,
                    sampleCount)
            }

            // Output buffer may be larger than what the tap supplied.
            if outBuffer.mDataByteSize > byteCount {
                memset(destination.advanced(by: Int(byteCount)), 0,
                       Int(outBuffer.mDataByteSize - byteCount))
            }
        }
    }

    // MARK: - Helpers

    static func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
            deviceID != kAudioObjectUnknown else { return nil }
        return AudioProcessController.string(deviceID, kAudioDevicePropertyDeviceUID)
    }

    private func fail(_ message: String, _ status: OSStatus) {
        let text = status == noErr ? message : "\(message) (\(Self.describe(status)))"
        errorMessage = text
        log.error("\(text, privacy: .public)")
        invalidate()
    }

    /// Core Audio errors are usually four-char codes, which are far easier to
    /// look up than the signed decimal Swift prints by default.
    static func describe(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff),
                     UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }),
           let text = String(bytes: bytes, encoding: .ascii) {
            return "'\(text)'"
        }
        return String(status)
    }
}
