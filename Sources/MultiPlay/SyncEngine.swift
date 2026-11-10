import AVFoundation
import CoreAudio
import Foundation
import os

// How it works
// ------------
// 1. A CoreAudio *process tap* captures everything the Mac plays (except MultiPlay itself)
//    and mutes it at the source, so nothing plays "directly" any more.
// 2. The captured audio is written into a shared ring buffer.
// 3. One AVAudioEngine per speaker reads from that buffer. Each reader stays a fixed
//    number of frames behind the writer, so the low-latency speaker (MacBook) is held
//    back until the high-latency one (Bluetooth) catches up. Small clock drift between
//    devices is corrected one frame at a time, which is inaudible.

/// Single-writer / multi-reader ring of interleaved stereo Float32 frames.
final class RingBuffer {
    let capacity: Int
    private let data: UnsafeMutablePointer<Float>
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var _writeIndex = 0
    private var _anchorHostTime: UInt64 = 0

    /// Test beeps mixed into the stream so speakers can be aligned by ear.
    var testBeeps = false
    let sampleRate: Double
    /// Loudest sample written since last reset (diagnostics only).
    var peak: Float = 0

    init(seconds: Double, sampleRate: Double) {
        self.sampleRate = sampleRate
        capacity = Int(seconds * sampleRate)
        data = .allocate(capacity: capacity * 2)
        data.initialize(repeating: 0, count: capacity * 2)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        data.deallocate()
        lock.deallocate()
    }

    var writeIndex: Int {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return _writeIndex
    }

    /// A frame index and the host time (mach ticks) at which that frame was captured.
    /// Lets the calibrator map ring positions to real time.
    var anchor: (index: Int, hostTime: UInt64) {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return (_writeIndex, _anchorHostTime)
    }

    /// `left`/`right` may point into the same interleaved buffer with `stride` 2.
    /// `hostTime` is when the first of these frames was captured.
    func write(frames: Int, left: UnsafePointer<Float>, right: UnsafePointer<Float>, stride: Int, hostTime: UInt64) {
        let start = _writeIndex // only the writer thread mutates it
        let beepLength = Int(sampleRate * 0.03)
        let period = Int(sampleRate)
        for i in 0..<frames {
            let absolute = start + i
            let slot = (absolute % capacity) * 2
            var l = left[i * stride], r = right[i * stride]
            if testBeeps {
                let phase = absolute % period
                if phase < beepLength {
                    let s = Float(0.5 * sin(2 * Double.pi * 1000 * Double(phase) / sampleRate))
                    l += s; r += s
                }
            }
            data[slot] = l
            data[slot + 1] = r
            peak = max(peak, abs(l), abs(r))
        }
        os_unfair_lock_lock(lock)
        _writeIndex = start + frames
        // Host time of frame `start + frames` (the next one to be written).
        _anchorHostTime = hostTime &+ AVAudioTime.hostTime(forSeconds: Double(frames) / sampleRate)
        os_unfair_lock_unlock(lock)
    }

    func read(from start: Int, frames: Int, gain: Float, into left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>) {
        for i in 0..<frames {
            let absolute = start + i
            if absolute < 0 { left[i] = 0; right[i] = 0; continue }
            let slot = (absolute % capacity) * 2
            left[i] = data[slot] * gain
            right[i] = data[slot + 1] * gain
        }
    }
}

/// Plays the ring buffer on one output device with a configurable delay.
final class DevicePlayer {
    let device: OutputDevice
    let engine = AVAudioEngine()
    /// How long this speaker takes from "we hand it audio" to "sound comes out".
    let latencySeconds: Double

    /// Extra delay (frames) that lines this speaker up with the others. Read on the audio thread.
    var delayFrames = 0
    /// While set, music is muted and this player only plays the calibration chirps.
    var calibration: ChirpSchedule?
    private let ring: RingBuffer
    private var readIndex: Int?
    /// Frames of real (non-silence-padding) audio played (diagnostics only).
    private(set) var renderedFrames = 0
    private(set) var renderCalls = 0
    private(set) var restarts = 0
    var outputDeviceName: String {
        guard let unit = engine.outputNode.audioUnit else { return "?" }
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size)
        return CoreAudioHAL.string(id, kAudioObjectPropertyName) ?? "\(id)"
    }
    /// Cushion that absorbs jitter between the capture and playback callbacks.
    let baseFrames: Int

    init(device: OutputDevice, ring: RingBuffer) throws {
        self.device = device
        self.ring = ring
        baseFrames = Int(ring.sampleRate * 0.04)
        latencySeconds = CoreAudioHAL.outputLatency(device.id)

        // Point this engine's output at the chosen speaker.
        var deviceID = device.id
        guard let unit = engine.outputNode.audioUnit else { throw AudioError.message("No output unit for \(device.name)") }
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw AudioError.osStatus("Selecting \(device.name)", status) }

        let format = AVAudioFormat(standardFormatWithSampleRate: ring.sampleRate, channels: 2)!
        let source = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, bufferList in
            self.render(frames: Int(frameCount), bufferList)
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()

        // AVAudioEngine stops itself when the device's configuration changes (e.g. the capture
        // device starting can change the speaker's sample rate). Just start it again.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, !self.stopped else { return }
            self.restarts += 1
            try? self.engine.start()
        }
    }

    private var configObserver: NSObjectProtocol?
    private var stopped = false

    func stop() {
        stopped = true
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine.stop()
    }

    private func render(frames: Int, _ bufferList: UnsafeMutablePointer<AudioBufferList>) {
        renderCalls += 1
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        guard abl.count >= 2,
              let left = abl[0].mData?.assumingMemoryBound(to: Float.self),
              let right = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return }

        let target = baseFrames + delayFrames
        let written = ring.writeIndex
        var read = readIndex ?? (written - target)
        let error = (written - read) - target
        let tolerance = Int(ring.sampleRate * 0.002) // 2 ms

        if abs(error) > Int(ring.sampleRate * 0.05) {
            read = written - target          // big jump (start, slider moved): snap
        } else if error > tolerance {
            read += 1                        // we're too far behind: skip one frame
        } else if error < -tolerance {
            read -= 1                        // too close to the writer: repeat one frame
        }

        if let calibration {
            calibration.render(from: read, frames: frames, into: left, right)
            read += frames
        } else if written - read < frames {  // not enough audio yet
            memset(left, 0, frames * 4); memset(right, 0, frames * 4)
        } else {
            ring.read(from: read, frames: frames, gain: 1, into: left, right)
            read += frames
            renderedFrames += frames
        }
        readIndex = read
    }
}

/// Chirps to play at given ring-buffer frame positions (silence everywhere else).
final class ChirpSchedule {
    let signal: [Float]
    let starts: [Int]

    init(signal: [Float], starts: [Int]) {
        self.signal = signal
        self.starts = starts
    }

    func render(from position: Int, frames: Int, into left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>) {
        memset(left, 0, frames * 4); memset(right, 0, frames * 4)
        for start in starts where start < position + frames && start + signal.count > position {
            for i in 0..<frames {
                let k = position + i - start
                if k >= 0 && k < signal.count { left[i] = signal[k]; right[i] = signal[k] }
            }
        }
    }
}

/// Captures all system audio via a muted process tap.
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// Diagnostics: capture callbacks so far, and the shape of the last input.
    private(set) var callbacks = 0
    private(set) var lastInputShape = ""
    /// Rate the captured audio actually arrives at. This is the capture device's rate (set by the
    /// clock speaker, e.g. 44.1 kHz for some Bluetooth speakers), which can differ from the tap's
    /// own format. The ring buffer must use this rate.
    let sampleRate: Double
    private let description: CATapDescription

    /// `clockUID`: the device whose clock paces the capture. Built-in speakers are the steadiest choice.
    init(clockUID: String) throws {
        guard let me = CoreAudioHAL.processObject(pid: getpid()) else {
            throw AudioError.message("Couldn't identify MultiPlay to CoreAudio")
        }
        description = CATapDescription(stereoGlobalTapButExcludeProcesses: [me])
        description.uuid = UUID()
        description.name = "MultiPlay capture"
        description.isPrivate = true
        description.muteBehavior = .muted // silence the original output; we replay it ourselves

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw AudioError.osStatus("Capturing system audio", status) }
        tapID = tap

        // A private device that reads the tap, clocked by `clockUID`.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MultiPlay Capture",
            kAudioAggregateDeviceUIDKey: "\(CoreAudioHAL.aggregateUID).capture.\(description.uuid.uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // No kAudioAggregateDeviceTapAutoStartKey: on macOS 26 it can leave the device stalled
            // (zero IO callbacks). The tap starts with the device's IO anyway.
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            throw AudioError.osStatus("Creating capture device", status)
        }
        aggregateID = agg
        sampleRate = CoreAudioHAL.nominalSampleRate(agg)
    }

    func start(into ring: RingBuffer) throws {
        let agg = aggregateID
        var proc: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { _, input, inputTime, _, _ in
            let host = inputTime.pointee.mHostTime
            // The tap's stream(s) come last in the input list.
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            self.callbacks += 1
            if self.callbacks == 1 { // once: building strings on the audio thread can cause glitches
                self.lastInputShape = abl.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" }.joined(separator: ",")
            }
            guard let last = abl.last, let lastData = last.mData else { return }
            if last.mNumberChannels >= 2 {       // interleaved stereo
                let p = lastData.assumingMemoryBound(to: Float.self)
                let frames = Int(last.mDataByteSize) / (4 * Int(last.mNumberChannels))
                ring.write(frames: frames, left: p, right: p + 1, stride: Int(last.mNumberChannels), hostTime: host)
            } else if abl.count >= 2, let l = abl[abl.count - 2].mData {  // planar L / R
                let frames = Int(last.mDataByteSize) / 4
                ring.write(frames: frames, left: l.assumingMemoryBound(to: Float.self),
                           right: lastData.assumingMemoryBound(to: Float.self), stride: 1, hostTime: host)
            }
        }
        guard status == noErr, let proc else { throw AudioError.osStatus("Starting capture", status) }
        procID = proc
        status = AudioDeviceStart(agg, proc)
        guard status == noErr else { throw AudioError.osStatus("Starting capture", status) }
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }
}

/// Ties it together: one tap, one ring buffer, one player per speaker.
final class SyncEngine {
    private var tap: SystemAudioTap?
    private var ring: RingBuffer?
    private(set) var players: [DevicePlayer] = []

    /// One-line status for the self-test log.
    func diagnostics() -> String {
        guard let ring else { return "stopped" }
        let peak = ring.peak; ring.peak = 0
        let p = players.map { "\($0.device.name): latency \(Int($0.latencySeconds * 1000))ms delay \(Int(Double($0.delayFrames) / ring.sampleRate * 1000))ms rendered \($0.renderedFrames) calls \($0.renderCalls) running \($0.engine.isRunning) restarts \($0.restarts) dev \($0.outputDeviceName)" }
        let capture = tap.map { "callbacks \($0.callbacks) input [\($0.lastInputShape)] " } ?? ""
        return capture + "rate \(Int(ring.sampleRate)) written \(ring.writeIndex) peak \(String(format: "%.3f", peak)) | " + p.joined(separator: " | ")
    }

    var isRunning: Bool { tap != nil }
    var sampleRate: Double? { ring?.sampleRate }
    var anchor: (index: Int, hostTime: UInt64)? { ring?.anchor }

    var testBeeps: Bool {
        get { ring?.testBeeps ?? false }
        set { ring?.testBeeps = newValue }
    }

    /// `delaysMs`: extra delay per device UID. Devices missing from it get an estimate.
    func start(devices: [OutputDevice], delaysMs: [String: Double]?) throws {
        stop()
        do {
            // Clock the capture from wired/built-in hardware when possible; Bluetooth clocks are less steady.
            let clock = devices.first(where: \.isBuiltIn) ?? devices.first(where: { !$0.isBluetooth }) ?? devices[0]
            let tap = try SystemAudioTap(clockUID: clock.uid)
            let ring = RingBuffer(seconds: 4, sampleRate: tap.sampleRate)
            self.tap = tap
            self.ring = ring
            players = try devices.map { try DevicePlayer(device: $0, ring: ring) }
            setDelays(ms: delaysMs ?? estimatedDelaysMs())
            try tap.start(into: ring)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        tap?.stop()
        tap = nil
        players.forEach { $0.stop() }
        players = []
        ring = nil
    }

    func setDelays(ms: [String: Double]) {
        guard let ring else { return }
        let estimates = estimatedDelaysMs()
        for player in players {
            let value = ms[player.device.uid] ?? estimates[player.device.uid] ?? 0
            player.delayFrames = Int(max(0, value) / 1000 * ring.sampleRate)
        }
    }

    func delaysMs() -> [String: Double] {
        guard let ring else { return [:] }
        return Dictionary(uniqueKeysWithValues: players.map { ($0.device.uid, Double($0.delayFrames) / ring.sampleRate * 1000) })
    }

    /// First guess from the latency each device reports (Bluetooth usually under-reports).
    func estimatedDelaysMs() -> [String: Double] {
        let slowest = players.map(\.latencySeconds).max() ?? 0
        return Dictionary(uniqueKeysWithValues: players.map { ($0.device.uid, (slowest - $0.latencySeconds) * 1000) })
    }
}
