import CoreAudio
import Foundation

/// An output-capable audio device (speakers, Bluetooth speaker, headphones, ...).
struct OutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }

    var symbol: String {
        if isBluetooth { return "hifispeaker.fill" }
        if isBuiltIn { return "laptopcomputer" }
        if transport == kAudioDeviceTransportTypeAirPlay { return "airplayaudio" }
        if transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort { return "tv" }
        if transport == kAudioDeviceTransportTypeVirtual { return "waveform" }
        return "speaker.wave.2.fill"
    }
}

enum AudioError: LocalizedError {
    case osStatus(String, OSStatus)
    case message(String)
    var errorDescription: String? {
        switch self {
        case let .osStatus(what, status): return "\(what) failed (OSStatus \(status))"
        case let .message(text): return text
        }
    }
}

/// Thin wrappers around the CoreAudio HAL.
enum CoreAudioHAL {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    /// Physical/virtual output devices, excluding aggregate devices (including our own).
    static func outputDevices() -> [OutputDevice] {
        allDeviceIDs().compactMap { id in
            guard hasOutputStreams(id),
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            let transport = uint32(id, kAudioDevicePropertyTransportType) ?? 0
            if transport == kAudioDeviceTransportTypeAggregate { return nil }
            return OutputDevice(id: id, uid: uid, name: name, transport: transport)
        }
    }

    static func device(withUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    // MARK: Latency / process / input

    /// CoreAudio object for a process (used to exclude MultiPlay from its own capture).
    static func processObject(pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func defaultInputDevice() -> AudioDeviceID? {
        uint32(systemObject, kAudioHardwarePropertyDefaultInputDevice)
    }

    /// The Mac's own microphone (used for auto-sync).
    static func builtInMicrophone() -> AudioDeviceID? {
        allDeviceIDs().first { id in
            var addr = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
            var size: UInt32 = 0
            return uint32(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn
                && AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
        }
    }

    static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate)
        return rate > 0 ? rate : 48_000
    }

    /// Reported output latency in seconds: device + safety offset + IO buffer + stream latency.
    /// Bluetooth devices include their radio/codec delay here, though not always exactly.
    static func outputLatency(_ id: AudioDeviceID) -> Double {
        func frames(_ selector: AudioObjectPropertySelector) -> UInt32 {
            var addr = address(selector, scope: kAudioObjectPropertyScopeOutput)
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
            return value
        }
        var total = frames(kAudioDevicePropertyLatency) + frames(kAudioDevicePropertySafetyOffset)
            + frames(kAudioDevicePropertyBufferFrameSize)

        // Latency of the first output stream.
        var addr = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 {
            var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &streams) == noErr, let first = streams.first {
                total += uint32(first, kAudioStreamPropertyLatency) ?? 0
            }
        }
        return Double(total) / nominalSampleRate(id)
    }

    // MARK: Volume (per device)

    /// Returns the elements that expose a settable volume: the main element, or else channels 1 & 2.
    private static func volumeElements(_ id: AudioDeviceID) -> [AudioObjectPropertyElement] {
        for candidates in [[kAudioObjectPropertyElementMain], [1, 2]] as [[AudioObjectPropertyElement]] {
            let ok = candidates.allSatisfy { el in
                var addr = address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: el)
                var settable: DarwinBoolean = false
                return AudioObjectHasProperty(id, &addr)
                    && AudioObjectIsPropertySettable(id, &addr, &settable) == noErr && settable.boolValue
            }
            if ok { return candidates }
        }
        return []
    }

    static func volume(_ id: AudioDeviceID) -> Float? {
        guard let el = volumeElements(id).first else { return nil }
        var addr = address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: el)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func setVolume(_ id: AudioDeviceID, _ volume: Float) {
        var value = Float32(max(0, min(1, volume)))
        for el in volumeElements(id) {
            var addr = address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: el)
            AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
    }

    // MARK: Leftover devices

    /// Prefix of every aggregate device MultiPlay creates.
    static let aggregateUID = "com.multiplay.multi-output"

    /// Removes devices left by older versions or a crash.
    static func destroyLeftoverDevices() {
        for id in allDeviceIDs() where string(id, kAudioDevicePropertyDeviceUID)?.hasPrefix(aggregateUID) == true {
            AudioHardwareDestroyAggregateDevice(id)
        }
    }

    // MARK: Change notifications

    static func onDevicesChanged(_ handler: @escaping () -> Void) {
        var addr = address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(systemObject, &addr, DispatchQueue.main) { _, _ in handler() }
    }
}
