import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: AudioController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu bar only, no Dock icon
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Put audio back the way it was when quitting.
        MainActor.assumeIsolated { controller?.stop() }
    }
}

@main
struct MultiPlayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var audio = AudioController()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(audio)
                .onAppear { appDelegate.controller = audio }
        } label: {
            Image(systemName: audio.isActive ? "hifispeaker.2.fill" : "hifispeaker.2")
                .onAppear { appDelegate.controller = audio }
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuView: View {
    @EnvironmentObject var audio: AudioController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MultiPlay").font(.headline)
                    Text(audio.isActive ? "Playing on \(audio.activeSelection.count) outputs" : "Off")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { audio.isActive }, set: { audio.setActive($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            Divider()

            Text("OUTPUTS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)

            if audio.devices.isEmpty {
                Text("No output devices found").foregroundStyle(.secondary)
            }
            ForEach(audio.devices) { device in
                DeviceRow(device: device)
            }

            if let error = audio.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            if audio.isActive {
                SyncSection()
            } else {
                Text("Connect your Bluetooth speaker in System Settings first. The first time you turn MultiPlay on, macOS asks to allow system audio recording and the microphone: it listens to a few short chirps to sync the speakers automatically.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button("Sound Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 300)
    }
}

struct DeviceRow: View {
    @EnvironmentObject var audio: AudioController
    let device: OutputDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { audio.isSelected(device) }, set: { _ in audio.toggle(device) })) {
                Label(device.name, systemImage: device.symbol)
                    .lineLimit(1)
            }
            .toggleStyle(.checkbox)

            if audio.isSelected(device) {
                VStack(alignment: .leading, spacing: 2) {
                    // Per-device volume (keyboard volume keys only affect the default output).
                    if let volume = audio.volume(of: device) {
                        HStack(spacing: 6) {
                            Image(systemName: "speaker.fill").font(.caption2).foregroundStyle(.secondary).frame(width: 14)
                            Slider(value: Binding(get: { volume }, set: { audio.setVolume($0, for: device) }), in: 0...1)
                                .controlSize(.small)
                        }
                    }
                }
                .padding(.leading, 22)
            }
        }
    }
}

struct SyncSection: View {
    @EnvironmentObject var audio: AudioController
    @State private var showManual = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if audio.isSyncing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Text(audio.syncStatus ?? "In sync")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Re-sync") { audio.autoSync() }
                    .controlSize(.small)
                    .disabled(audio.isSyncing)
                    .help("Plays a few chirps and listens with the Mac's microphone to line the speakers up. Run it again if you move a speaker.")
            }

            DisclosureGroup("Manual adjust", isExpanded: $showManual) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(audio.activeSelection) { device in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(device.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            HStack(spacing: 6) {
                                Slider(value: Binding(get: { audio.delay(of: device) }, set: { audio.setDelay($0, for: device) }),
                                       in: 0...600)
                                    .controlSize(.small)
                                Text("\(Int(audio.delay(of: device))) ms")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(width: 48, alignment: .trailing)
                            }
                        }
                    }
                    Toggle("Test beeps (one beep a second)", isOn: $audio.testBeeps)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.caption2)
                }
                .padding(.top, 4)
                .disabled(audio.isSyncing)
            }
            .font(.caption)
        }
    }
}
