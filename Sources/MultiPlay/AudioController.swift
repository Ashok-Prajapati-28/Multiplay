import AppKit
import AVFoundation
import CoreAudio
import Foundation

@MainActor
final class AudioController: ObservableObject {
    @Published private(set) var devices: [OutputDevice] = []
    @Published private(set) var selectedUIDs: Set<String>
    @Published private(set) var isActive = false
    @Published var errorMessage: String?
    @Published private(set) var isSyncing = false
    /// Short line about the last auto-sync ("Synced", "Couldn't hear …").
    @Published private(set) var syncStatus: String?
    @Published var testBeeps = false {
        didSet { engine.testBeeps = testBeeps }
    }

    private let engine = SyncEngine()
    private let defaults = UserDefaults.standard
    /// Saved delays (ms by device UID) for each combination of speakers, keyed by `comboKey`.
    private var profiles: [String: [String: Double]]
    private var lastActiveUIDs: [String] = []
    private var restartWork: DispatchWorkItem?
    private var startedAt = Date.distantPast
    private var syncTask: Task<Void, Never>?

    init() {
        selectedUIDs = Set(defaults.stringArray(forKey: "selectedUIDs") ?? [])
        profiles = (defaults.dictionary(forKey: "syncProfiles") as? [String: [String: Double]]) ?? [:]
        // Remove devices left behind by older versions of MultiPlay or a force-quit.
        CoreAudioHAL.destroyLeftoverDevices()
        refresh()
        CoreAudioHAL.onDevicesChanged { [weak self] in
            Task { @MainActor in self?.devicesChanged() }
        }
        // After sleep the capture device can stop delivering audio; rebuild to be safe.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                try? await Task.sleep(for: .seconds(2)) // let Bluetooth reconnect
                if self.isActive { self.rebuild() }
            }
        }
        if let mode = ProcessInfo.processInfo.environment["MULTIPLAY_SELFTEST"] { runSelfTest(mode: mode) }
    }

    /// Selected devices that are currently connected.
    var activeSelection: [OutputDevice] {
        devices.filter { selectedUIDs.contains($0.uid) }
    }

    func isSelected(_ device: OutputDevice) -> Bool { selectedUIDs.contains(device.uid) }

    func toggle(_ device: OutputDevice) {
        if selectedUIDs.contains(device.uid) { selectedUIDs.remove(device.uid) } else { selectedUIDs.insert(device.uid) }
        defaults.set(Array(selectedUIDs), forKey: "selectedUIDs")
        if isActive { rebuild() }
    }

    func setActive(_ on: Bool) { on ? start() : stop() }

    // MARK: - Sync

    private var comboKey: String { activeSelection.map(\.uid).sorted().joined(separator: "|") }

    /// Current delay for a speaker (ms), as applied by the engine.
    func delay(of device: OutputDevice) -> Double { engine.delaysMs()[device.uid] ?? 0 }

    /// Manual tweak from the slider; saved for this speaker combination.
    func setDelay(_ ms: Double, for device: OutputDevice) {
        var delays = engine.delaysMs()
        delays[device.uid] = ms.rounded()
        engine.setDelays(ms: delays)
        saveProfile(delays)
        syncStatus = "Adjusted by hand"
        objectWillChange.send()
    }

    /// Plays chirps, listens with the mic, and sets every speaker's delay automatically.
    func autoSync() {
        guard isActive, !isSyncing else { return }
        isSyncing = true
        syncStatus = "Syncing… (music pauses for a few seconds)"
        errorMessage = nil
        let wasBeeping = testBeeps
        testBeeps = false
        syncTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Calibrator.run(engine: self.engine)
                guard self.isActive else { return }
                self.engine.setDelays(ms: result.delaysMs)
                self.saveProfile(result.delaysMs)
                var status = "Synced automatically"
                if !result.unheard.isEmpty {
                    status += ". Couldn't hear \(result.unheard.joined(separator: ", ")), so its delay is unchanged"
                }
                self.syncStatus = status
                self.log("sync result: delays \(result.delaysMs.mapValues { Int($0) }) measured latency \(result.measuredMs.mapValues { Int($0) }) jitter \(String(format: "%.1f", result.jitterMs))ms unheard \(result.unheard) raw \(result.rawMs)")
            } catch is CancellationError {
                self.syncStatus = nil
            } catch {
                self.syncStatus = nil
                self.errorMessage = error.localizedDescription
                self.log("sync error: \(error.localizedDescription)")
            }
            self.isSyncing = false
            self.testBeeps = wasBeeping
        }
    }

    private func saveProfile(_ delays: [String: Double]) {
        profiles[comboKey] = delays
        defaults.set(profiles, forKey: "syncProfiles")
    }

    // MARK: - Volume

    func volume(of device: OutputDevice) -> Float? { CoreAudioHAL.volume(device.id) }
    func setVolume(_ v: Float, for device: OutputDevice) {
        CoreAudioHAL.setVolume(device.id, v)
        objectWillChange.send()
    }

    // MARK: - Lifecycle

    func start() {
        errorMessage = nil
        cancelSync()
        let selection = activeSelection
        guard selection.count >= 2 else {
            errorMessage = "Pick at least two connected outputs."
            stop()
            return
        }
        // Capture stays silent until macOS has a permission decision, so get one first.
        switch SystemAudioPermission.status {
        case .granted: break
        case .denied:
            errorMessage = "MultiPlay isn't allowed to capture system audio. Turn it on in System Settings → Privacy & Security → Screen & System Audio Recording (\"System Audio Recording Only\"), then try again."
            return
        case .notAsked:
            log("requesting system audio permission")
            Task {
                let granted = await SystemAudioPermission.request()
                log("system audio permission granted: \(granted)")
                if granted { start() } else { errorMessage = "MultiPlay needs permission to capture system audio." }
            }
            return
        }
        do {
            let saved = profiles[comboKey]
            try engine.start(devices: selection, delaysMs: saved)
            engine.testBeeps = testBeeps
            lastActiveUIDs = selection.map(\.uid)
            startedAt = Date()
            isActive = true
            // Watchdog: if no audio has been captured after a few seconds, say why instead of staying silent.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.isActive, (self.engine.anchor?.index ?? 0) == 0 else { return }
                self.cancelSync()
                self.errorMessage = "MultiPlay can't capture system audio. Allow it in System Settings → Privacy & Security → Screen & System Audio Recording (\"System Audio Recording Only\"), then turn MultiPlay off and on."
                self.log("watchdog: capture not running")
            }
            if saved == nil {
                // New speaker combination: measure it once, automatically.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.autoSync() }
            } else {
                syncStatus = "Using saved sync"
            }
        } catch {
            errorMessage = error.localizedDescription
            isActive = false
        }
    }

    func stop() {
        cancelSync()
        engine.stop()
        isActive = false
        testBeeps = false
        syncStatus = nil
    }

    private func cancelSync() {
        syncTask?.cancel()
        syncTask = nil
        isSyncing = false
    }

    private func rebuild() {
        if activeSelection.count >= 2 { start() } else { stop() }
    }

    private func scheduleRestart() {
        // Starting the engines (or the mic during auto-sync) can trigger configuration changes; ignore those.
        guard isActive, !isSyncing, Date().timeIntervalSince(startedAt) > 2 else { return }
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in Task { @MainActor in self?.rebuild() } }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func refresh() {
        devices = CoreAudioHAL.outputDevices().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func devicesChanged() {
        refresh()
        // A selected speaker connected/disconnected while running: rebuild so it joins/leaves.
        if isActive && activeSelection.map(\.uid) != lastActiveUIDs { scheduleRestart() }
    }

    // MARK: - Self-test

    private var selfTest = false
    private func log(_ line: String) {
        if selfTest { FileHandle.standardError.write((line + "\n").data(using: .utf8)!) }
    }

    /// Hidden self-test, logging to stderr then quitting. Doesn't change the saved speaker selection.
    /// MULTIPLAY_SELFTEST=1: play on every output for 8 s.
    /// MULTIPLAY_SELFTEST=sync: auto-sync all real (non-virtual) outputs from scratch, then play 4 s.
    /// MULTIPLAY_SELFTEST=verify: re-run auto-sync starting from the saved delays (should barely change them).
    private func runSelfTest(mode: String) {
        selfTest = true
        let verify = mode == "verify" // re-measure starting from the saved delays
        let sync = mode == "sync" || verify
        selectedUIDs = Set(devices.filter { !sync || $0.transport != kAudioDeviceTransportTypeVirtual }.map(\.uid))
        if mode == "sync" { profiles[comboKey] = nil }
        start()
        if verify { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.autoSync() } }
        log("selftest start: \(errorMessage ?? "ok") outputs: \(activeSelection.map(\.name)) permission: \(SystemAudioPermission.status) mic: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (3=allowed)")
        Task {
            // Wait (up to a minute) for the user to answer a permission prompt.
            for _ in 0..<300 where !isActive { try? await Task.sleep(for: .milliseconds(200)) }
            if sync {
                try? await Task.sleep(for: .seconds(1.5))
                while isSyncing { try? await Task.sleep(for: .milliseconds(200)) }
            }
            for second in 1...(sync ? 4 : 8) {
                try? await Task.sleep(for: .seconds(1))
                log("t=\(second)s \(engine.diagnostics())")
            }
            stop()
            exit(0)
        }
    }
}
