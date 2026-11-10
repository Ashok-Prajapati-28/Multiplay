# MultiPlay

**Play your Mac's audio on several speakers at once, in sync.** For example, your MacBook speakers and a Bluetooth speaker together, with no echo between them.

MultiPlay is a small menu bar app. It works with every app (Spotify, Apple Music, YouTube in a browser, games, …) and **syncs the speakers automatically**: it plays a few short chirps, listens with the Mac's microphone, and works out how much to delay each speaker.

- Any number of outputs: built-in speakers, Bluetooth, USB, HDMI, AirPlay.
- Automatic sync, saved per speaker combination, plus a one-click **Re-sync**.
- Per-speaker volume.
- Speakers can come and go; it adapts when one connects or disconnects.
- No network access. Audio never leaves your Mac.

## Why not macOS's built-in "Multi-Output Device"?

Audio MIDI Setup can already send sound to several outputs. But Bluetooth speakers play about 150–250 ms later than wired ones, and a Multi-Output Device can't delay the fast ones to match. You hear an echo. MultiPlay measures each speaker's real delay and lines them up.

## Requirements

- macOS 14.4 (Sonoma) or newer, on Apple Silicon or Intel
- A microphone for auto-sync (every MacBook and iMac has one). Without a mic, you can still sync by hand.
- To build from source: Xcode, or the Command Line Tools (`xcode-select --install`)

## Install

### Option A: build from source (recommended)

```bash
git clone https://github.com/Ashok-Prajapati-28/MultiPlay.git
```

```bash
cd MultiPlay && scripts/create-signing-cert.sh && ./build.sh --install
```

- `scripts/create-signing-cert.sh` (one time) creates a local self-signed certificate called "MultiPlay Dev". macOS ties MultiPlay's permissions to its signature, so with this certificate they survive rebuilds. Without it, macOS silently forgets them every time you rebuild. The certificate stays on your Mac, and you can delete it in Keychain Access at any time.
- `./build.sh --install` builds the app, copies it to `/Applications`, and launches it.

### Option B: download a release

1. Download `MultiPlay-x.y.z.zip` from the [Releases](../../releases) page, unzip it, and drag **MultiPlay.app** to Applications.
2. The app isn't notarized by Apple, so macOS will refuse to open it the first time. Clear the download flag once:

   ```bash
   xattr -dr com.apple.quarantine /Applications/MultiPlay.app
   ```

   Alternatively, right-click the app → **Open** → **Open**. Then launch it normally.

## Usage

1. Connect your Bluetooth speaker in **System Settings → Bluetooth**.
2. Click the speaker icon in the menu bar and tick the outputs you want (at least two).
3. Turn on the switch. The first time, macOS asks for two permissions. Allow both:
   - **System Audio Recording**: lets MultiPlay take what your Mac plays and replay it on each speaker with the right delay.
   - **Microphone**: used only during auto-sync, to hear the chirps.
4. The first time you use a combination of speakers, MultiPlay **syncs automatically**. Music pauses for about 5 seconds while each speaker chirps. The result is saved.

Turning MultiPlay off, or quitting it, returns sound to normal. To start it at login: **System Settings → General → Login Items → +** → MultiPlay.

### Sync

- **Re-sync**: run it after moving a speaker, or if something ever sounds slightly off. A Bluetooth speaker's delay shifts a little (about ±15 ms) each time audio restarts. A fresh sync is exact; a saved one is very close.
- **Manual adjust** (collapsed in the menu): a delay slider per speaker, and test beeps. With beeps on, a double beep means one speaker is early; raise that speaker's slider until the beeps merge.

## Privacy

- System audio is captured only while MultiPlay is on, and only so it can be replayed on your speakers. It's kept in a 4-second memory buffer and never written to disk.
- The microphone is used only during a sync, for a few seconds. The recording is analysed in memory and discarded.
- MultiPlay makes no network connections.

## How it works

```
apps ──► system audio ──► process tap (captures + mutes) ──► ring buffer
                                                           ├─► MacBook speakers  (delayed by X ms)
                                                           └─► Bluetooth speaker (delayed by Y ms)
```

1. A CoreAudio **process tap** captures everything the Mac plays, except MultiPlay itself, and mutes the original, so nothing plays directly any more.
2. The captured audio goes into a shared **ring buffer**.
3. Each speaker gets its own **AVAudioEngine** that reads from the buffer at a fixed distance behind the newest audio. Faster speakers are read further behind, so sound leaves every speaker at the same moment.
4. Devices run on slightly different clocks. Each player corrects drift by skipping or repeating a single sample when it slips more than 2 ms, which you can't hear.
5. The capture is clocked by built-in or wired hardware when one is selected, because Bluetooth clocks are less steady.

### Auto-sync

1. Music is muted, and each speaker in turn plays a 60 ms rising chirp (1.5 → 7 kHz), 4 times each.
2. The built-in microphone records with precise timestamps from the CoreAudio host clock.
3. For each chirp, MultiPlay knows when it was *sent* (its buffer position mapped to the host clock). It finds when it *arrived* by cross-correlating the recording with the chirp (Accelerate / vDSP).
4. arrival − sent = our delay + that speaker's real latency + the mic's latency. The mic part is the same for every speaker, so it cancels out.
5. Detections more than 15 ms from the median (noise, echoes) are discarded. Each speaker then gets a delay of (slowest latency − its latency).

On a MacBook Pro with a JBL Clip 4, repeated chirps agree to within about 5 ms. The speaker measured about 150 ms slower than the built-in speakers, though it reports only 72 ms more.

## Known limitations

- **Extra delay:** everything plays about 40 ms later, plus the slowest speaker's own delay. That's fine for music, but lip-sync on video may be slightly off.
- **Volume keys** only control the system's default output. Use the per-speaker sliders in the menu.
- **Sound only plays while MultiPlay is on.** If it crashes, sound returns to normal by itself.
- **Not notarized:** see Option B above.
- **Private API:** there's no public API to request the System Audio Recording permission, and on macOS 26 a capture doesn't prompt by itself. MultiPlay calls macOS's TCC framework directly (as the open-source [AudioCap](https://github.com/insidegui/AudioCap) sample does). This rules out the Mac App Store.
- **Bluetooth headsets:** if an app uses a Bluetooth headset's microphone, macOS switches that headset to low quality. MultiPlay always uses the built-in mic to avoid this.

## Troubleshooting

**Silence when MultiPlay is on, or "MultiPlay can't capture system audio":**

1. Check **System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only** → MultiPlay is on.
2. If it's on but still silent, the permission probably belongs to an older build. This is common if you rebuilt without the signing certificate. Reset it, turn MultiPlay on again, and click Allow:

   ```bash
   tccutil reset AudioCapture com.multiplay.app; tccutil reset Microphone com.multiplay.app
   ```

3. Still stuck? Restart macOS's audio service (sound drops for a second):

   ```bash
   sudo killall coreaudiod
   ```

**"Couldn't hear the speakers" during sync:** turn the speakers up, keep them within a few metres of the Mac, make the room reasonably quiet, then press Re-sync.

**Bluetooth speaker isn't listed:** make sure it's *connected*, not just paired. The list updates on its own.

## Development

| File | What it does |
| --- | --- |
| `Sources/MultiPlay/SyncEngine.swift` | Audio engine: system audio capture (process tap), ring buffer, per-speaker delayed players, drift correction |
| `Sources/MultiPlay/Calibrator.swift` | Auto-sync: chirp, microphone recorder, chirp detection, delay calculation |
| `Sources/MultiPlay/AudioController.swift` | App state: selection, per-combination delays, on/off, auto-sync, restarts, self-tests |
| `Sources/MultiPlay/AudioDevices.swift` | CoreAudio helpers: listing outputs, latency, sample rate, volume |
| `Sources/MultiPlay/Permissions.swift` | Checks and requests the System Audio Recording permission |
| `Sources/MultiPlay/MultiPlayApp.swift` | SwiftUI menu bar UI |
| `build.sh` | Builds, bundles and signs the app (`--install`, `--release`) |
| `scripts/create-signing-cert.sh` | Creates the local "MultiPlay Dev" signing certificate |

**Self-tests:** each logs to the terminal and then quits, leaving your saved speaker selection alone. Grant the permissions once first by turning MultiPlay on normally.

```bash
open -W --env MULTIPLAY_SELFTEST=1 --stderr /tmp/multiplay.log build/MultiPlay.app; cat /tmp/multiplay.log
```

```bash
open -W --env MULTIPLAY_SELFTEST=sync --stderr /tmp/multiplay.log build/MultiPlay.app; cat /tmp/multiplay.log
```

- `1`: plays on every output for 8 seconds. `callbacks` and `written` should keep growing, and `peak` above 0 means audio is being captured.
- `sync`: auto-syncs all real speakers from scratch and prints each one's measured latency and every raw chirp detection.
- `verify`: re-syncs starting from the saved delays.

**Making a release:** bump `VERSION` in `build.sh`, run `./build.sh --release`, and attach `build/MultiPlay-<version>.zip` to a GitHub release. Sign releases with the same certificate each time, so users' permissions carry over between versions.

**CI:** `.github/workflows/build.yml` builds the app on every push and pull request.

## License

[MIT](LICENSE)
