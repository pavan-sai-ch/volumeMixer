//
//  AudioProcessController.swift
//  volumeMixer
//
//  Enumerates processes that are currently sending audio to the output device.
//

import CoreAudio
import Observation

@MainActor
@Observable
final class AudioProcessController {
    private(set) var processes: [AudioProcess] = []

    /// Called after each refresh so the owner can release taps for dead processes.
    @ObservationIgnored var onRefresh: (() -> Void)?

    private var timer: Timer?

    func start() {
        refresh()
        // Core Audio posts no notification for "process started making sound",
        // so the audible set is polled. 1s is responsive without being costly.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let objects = Self.processObjectIDs()
        var found: [AudioProcess] = []

        for object in objects {
            // Only processes actively rendering output are worth a slider.
            guard Self.uint32(object, kAudioProcessPropertyIsRunningOutput) == 1 else { continue }
            let pid = pid_t(Self.int32(object, kAudioProcessPropertyPID) ?? -1)
            let bundleID = Self.string(object, kAudioProcessPropertyBundleID)
            // coreaudiod itself and our own re-render show up as output; skip them.
            if bundleID == Bundle.main.bundleIdentifier { continue }
            found.append(AudioProcess(id: object, pid: pid, bundleID: bundleID))
        }

        let sorted = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if sorted != processes { processes = sorted }
        onRefresh?()
    }

    // MARK: - Core Audio property helpers

    static func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func int32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Int32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Int32>.size)
        var value: Int32 = 0
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }
}
