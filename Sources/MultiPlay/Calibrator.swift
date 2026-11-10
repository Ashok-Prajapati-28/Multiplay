import Accelerate
import AVFoundation
import CoreAudio
import Foundation

// Automatic sync
// --------------
// Music is muted for a few seconds while each speaker, in turn, plays a short chirp
// (a quick rising whistle). The Mac's built-in microphone records it all. For every
// chirp we know when it was *sent* (its position in the ring buffer, mapped to host
// time) and we find when it *arrived* (cross-correlating the recording with the chirp).
//
//     arrival − sent = our delay + that speaker's true latency (+ a constant mic latency)
//
// Subtracting our delay leaves each speaker's true latency, so the right delay for each
// speaker is just (slowest latency − its latency). The mic latency is the same for every
// speaker and cancels out.

struct CalibrationResult {
    /// New delay per device UID (ms).
    var delaysMs: [String: Double]
    /// Measured latency per device name (ms), for display/logging.
    var measuredMs: [String: Double]
    /// Speakers the microphone couldn't hear; their delay was left unchanged.
    var unheard: [String]
    /// Worst disagreement between the accepted measurements of one speaker (ms).
    var jitterMs: Double
    /// Every individual detection (ms, relative), by device name, for diagnostics.
    var rawMs: [String: [Int]]
}

@MainActor
enum Calibrator {
    static let rounds = 4
    static let spacing = 0.8          // seconds between chirps
    static let searchWindow = 0.35    // ± seconds around where we expect each chirp

    static func run(engine: SyncEngine) async throws -> CalibrationResult {
        guard let ringRate = engine.sampleRate, !engine.players.isEmpty else {
            throw AudioError.message("Turn MultiPlay on first.")
        }
        try await requestMicrophone()

        let recorder = try MicRecorder()
        try recorder.start()
        defer { recorder.stop() }
        try await Task.sleep(for: .milliseconds(400)) // let the mic settle

        // Schedule chirps round-robin: A B A B A B …
        guard let anchor = engine.anchor else { throw AudioError.message("Audio capture isn't running.") }
        let players = engine.players
        let signal = chirp(sampleRate: ringRate)
        let firstFrame = anchor.index + Int(0.3 * ringRate)
        var events: [(player: DevicePlayer, frame: Int)] = []
        var starts: [ObjectIdentifier: [Int]] = [:]
        for round in 0..<rounds {
            for (i, player) in players.enumerated() {
                let frame = firstFrame + Int(Double(round * players.count + i) * spacing * ringRate)
                events.append((player, frame))
                starts[ObjectIdentifier(player), default: []].append(frame)
            }
        }
        for player in players {
            player.calibration = ChirpSchedule(signal: signal, starts: starts[ObjectIdentifier(player)] ?? [])
        }
        defer { players.forEach { $0.calibration = nil } }

        // Wait until the last chirp has come out of the slowest speaker.
        let slowest = players.map { expectedPath($0, ringRate) }.max() ?? 0.5
        let total = 0.3 + Double(events.count) * spacing + slowest + searchWindow + 0.2
        try await Task.sleep(for: .seconds(total))

        players.forEach { $0.calibration = nil }
        let recording = recorder.snapshot()
        recorder.stop()
        guard let micStart = recording.startSeconds, !recording.samples.isEmpty else {
            throw AudioError.message("The microphone didn't record anything.")
        }

        // Find each chirp in the recording.
        let template = chirp(sampleRate: recording.sampleRate)
        let anchorSeconds = AVAudioTime.seconds(forHostTime: anchor.hostTime)
        var paths: [ObjectIdentifier: [Double]] = [:]
        for event in events {
            let sent = anchorSeconds + Double(event.frame - anchor.index) / ringRate
            let expected = sent + expectedPath(event.player, ringRate)
            guard let arrival = findChirp(template, in: recording.samples, rate: recording.sampleRate,
                                          around: expected - micStart) else { continue }
            paths[ObjectIdentifier(event.player), default: []].append(micStart + arrival - sent)
        }

        // Turn arrival times into delays.
        var trueLatency: [String: Double] = [:]   // seconds, excluding our own delay
        var measured: [String: Double] = [:]
        var unheard: [String] = []
        var jitter = 0.0
        var raw: [String: [Int]] = [:]
        for player in players {
            let p = paths[ObjectIdentifier(player)] ?? []
            raw[player.device.name] = p.map { Int(($0 * 1000).rounded()) }
            // Ignore stray detections (a noise, an echo): keep those that agree with the median.
            let m = median(p.isEmpty ? [0] : p)
            let agreeing = p.filter { abs($0 - m) < 0.015 }
            guard agreeing.count >= 2 else { unheard.append(player.device.name); continue }
            jitter = max(jitter, (agreeing.max()! - agreeing.min()!) * 1000)
            let path = agreeing.reduce(0, +) / Double(agreeing.count)
            let ourDelay = Double(player.delayFrames) / ringRate
            trueLatency[player.device.uid] = path - ourDelay
            measured[player.device.name] = (path - ourDelay) * 1000
        }
        guard trueLatency.count >= 2 else {
            throw AudioError.message("Couldn't hear the speakers. Turn the volume up, keep the Bluetooth speaker within a few metres of the Mac, and try again.")
        }

        var delays = engine.delaysMs()
        let slowestLatency = trueLatency.values.max()!
        for (uid, latency) in trueLatency {
            delays[uid] = ((slowestLatency - latency) * 1000).rounded()
        }
        return CalibrationResult(delaysMs: delays, measuredMs: measured, unheard: unheard, jitterMs: jitter, rawMs: raw)
    }

    // MARK: - Helpers

    /// Where we currently expect a speaker's chirp: our cushion + delay + its reported latency.
    private static func expectedPath(_ player: DevicePlayer, _ rate: Double) -> Double {
        Double(player.baseFrames + player.delayFrames) / rate + player.latencySeconds
    }

    /// 60 ms rising sweep 1.5 → 7 kHz, faded in/out. Laptop speakers and small Bluetooth
    /// speakers both play this range well, and the sweep gives a sharp correlation peak.
    static func chirp(sampleRate: Double) -> [Float] {
        let duration = 0.06, f0 = 1500.0, f1 = 7000.0
        let n = Int(duration * sampleRate)
        return (0..<n).map { i in
            let t = Double(i) / sampleRate
            let phase = 2 * Double.pi * (f0 * t + (f1 - f0) * t * t / (2 * duration))
            let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1))
            return Float(0.35 * window * sin(phase))
        }
    }

    /// Returns the chirp's arrival time (seconds from the recording start), or nil if it isn't clearly there.
    static func findChirp(_ template: [Float], in samples: [Float], rate: Double, around center: Double) -> Double? {
        let p = template.count
        let from = max(0, Int((center - searchWindow) * rate))
        let to = min(samples.count - p, Int((center + searchWindow) * rate))
        guard to - from > p else { return nil }
        let outputCount = to - from
        var correlation = [Float](repeating: 0, count: outputCount)
        samples.withUnsafeBufferPointer { s in
            vDSP_conv(s.baseAddress! + from, 1, template, 1, &correlation, 1, vDSP_Length(outputCount), vDSP_Length(p))
        }
        var peak: Float = 0
        var peakIndex: vDSP_Length = 0
        vDSP_maxmgvi(correlation, 1, &peak, &peakIndex, vDSP_Length(outputCount))
        var average: Float = 0
        vDSP_meamgv(correlation, 1, &average, vDSP_Length(outputCount))
        guard average > 0, peak / average > 8 else { return nil } // not clearly above the noise
        return Double(from + Int(peakIndex)) / rate
    }

    private static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    private static func requestMicrophone() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
        default: break
        }
        throw AudioError.message("Auto-sync needs the microphone. Allow MultiPlay in System Settings → Privacy & Security → Microphone.")
    }
}

/// Records mono audio from the Mac's built-in microphone, with the host time of the first sample.
/// Uses a CoreAudio IO callback directly, which gives exact capture timestamps.
final class MicRecorder {
    private let device: AudioDeviceID
    private var procID: AudioDeviceIOProcID?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var startSeconds: Double?
    let sampleRate: Double

    init() throws {
        // Built-in mic even if a Bluetooth headset is connected (which would drop to low quality).
        guard let mic = CoreAudioHAL.builtInMicrophone() ?? CoreAudioHAL.defaultInputDevice() else {
            throw AudioError.message("No microphone available for auto-sync.")
        }
        device = mic
        sampleRate = CoreAudioHAL.nominalSampleRate(mic)
        samples.reserveCapacity(Int(sampleRate * 30)) // avoid growing the array on the audio thread
    }

    func start() throws {
        var proc: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { [weak self] _, input, inputTime, _, _ in
            guard let self else { return }
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = abl.first, let data = first.mData else { return }
            let channels = max(1, Int(first.mNumberChannels))
            let frames = Int(first.mDataByteSize) / (4 * channels)
            let p = data.assumingMemoryBound(to: Float.self)
            let host = inputTime.pointee.mHostTime
            self.lock.lock()
            if self.startSeconds == nil { self.startSeconds = AVAudioTime.seconds(forHostTime: host) }
            for i in 0..<frames { self.samples.append(p[i * channels]) } // first channel
            self.lock.unlock()
        }
        guard status == noErr, let proc else { throw AudioError.osStatus("Opening the microphone", status) }
        procID = proc
        status = AudioDeviceStart(device, proc)
        guard status == noErr else { throw AudioError.osStatus("Starting the microphone", status) }
    }

    func stop() {
        guard let procID else { return }
        AudioDeviceStop(device, procID)
        AudioDeviceDestroyIOProcID(device, procID)
        self.procID = nil
    }

    func snapshot() -> (samples: [Float], sampleRate: Double, startSeconds: Double?) {
        lock.lock(); defer { lock.unlock() }
        return (samples, sampleRate, startSeconds)
    }
}
