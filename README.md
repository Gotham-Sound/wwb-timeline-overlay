# wwb-overlay

Overlay Shure Wireless Workbench (WWB) Timeline telemetry on show video, in sync.
Proof of concept, started 2026-10-11.

Five parts:

1. `tline.py`: reference decoder for WWB Timeline recorder files (`.tline`). Stdlib only.
2. `shw.py`: pulls receiver model, band, frequency and linked transmitter per channel out of a WWB show file (`.shw`).
3. `player.html`: browser player. Drop a video, a `.tline` and optionally a `.shw` on it, set one sync anchor, and a translucent RF dashboard follows the video.
4. `render.py`: renders that dashboard as an alpha overlay movie for Resolve, or burns it into a preview MP4.
5. `app/`: a native Mac app around the player with its own renderer (drop files on the window, File > Render Overlay). No Python or ffmpeg needed.

## Quick start

Open `player.html` in a browser (double-click works, no server needed), drop the three files on it, and set the anchor: a video time you can identify (for example the moment a countdown hits zero) and the wall-clock time of that moment as WWB shows it. Use the Trim field, or the `,` and `.` keys, to nudge by 0.1 s while watching a mic being switched on.

For a preset session served over HTTP (seekable, shareable on the LAN):

```bash
python3 serve.py
```

then open `http://127.0.0.1:8765/player.html?video=data/bb.mp4&tline=data/bb.tline&shw=data/bb.shw`.
`data/` holds symlinks to the real files and is not committed.

## Mac app

`app/` holds a native wrapper: a window hosting the player, Finder drag-and-drop and File > Open for the files, and File > Render Overlay, which renders natively with Core Graphics and AVFoundation (ProRes 4444 with alpha, HEVC with alpha, or a PNG sequence, plus an optional burned-in preview MP4 with the program audio). The app has no dependencies beyond macOS 13: no Python, no ffmpeg. Build it with:

```bash
app/build.sh --run
```

That needs Xcode or the command line tools and produces `build/WWB Overlay.app` (arm64, ad-hoc signed, fine for this Mac). Double-clicking a `.tline` or `.shw` opens the app.

For a build that runs on other Macs, including Intel ones, use the release script:

```bash
app/release.sh                # universal binary, Developer ID + hardened runtime, notarize, staple
app/release.sh --no-notarize  # sign only
```

It signs with the Gotham Sound Developer ID from the keychain and writes `build/WWB Overlay.zip`. Notarization needs a one-time credential in the keychain (an app-specific password from appleid.apple.com, never stored in the repo):

```bash
xcrun notarytool store-credentials wwb-notary --apple-id <your apple id> --team-id LP4782R87F
```

Signing is done on a staged copy in `/tmp` because a synced Documents folder keeps re-adding Finder metadata that codesign rejects. The binary doubles as a command-line renderer:

```bash
"build/WWB Overlay.app/Contents/MacOS/WWB Overlay" --render --tline data/bb.tline --shw data/bb.shw \
    --start 2:35:53 --duration 120 --codec prores --out out/overlay.mov --burn-in data/bb.mp4
```

Flags mirror `render.py`. The dashboard rows show, per channel: RSSI A and B, channel quality pips, battery, the receiver's own RF meter pips ("RF"), ShowLink pips ("SL", dimmed when the rig has no access point), the audio meter, and a 20 s RSSI history with dropouts in red. On an M1 Max the native path renders 1080p ProRes 4444 plus the burned-in preview at roughly 80 frames per second end to end. ProRes 4444 is about 8 MB per second; HEVC with alpha is under 100 KB per second for a mostly transparent frame and is accepted by Resolve and Final Cut, but check your NLE version before relying on it.

The decoder, panel and writer live in `app/Timeline.swift`, `app/Panel.swift` and `app/Render.swift`; keep the panel geometry in step with `player.html` and `render.py`.

## Decoder CLI

```bash
python3 tline.py info  data/bb.tline --shw data/bb.shw
python3 tline.py dump  data/bb.tline --at 18:46:13 --slack 2
python3 tline.py export data/bb.tline --shw data/bb.shw --out out/bb --step 10 --active-only
```

`export` writes `manifest.json` (channels, devices, frequencies, events, start time), `events.csv` and a long-format `samples.csv` (one row per channel per sample). The full 10 Hz export of a 4 h, 16 channel show is about 70 MB; `--step 10` gives 1 Hz.

## Rendering an overlay for Resolve

`render.py` draws the same dashboard as the player, one frame per video frame, and pipes it into ffmpeg as a movie with an alpha channel. Nothing is written to disk except the output.

```bash
# 60 s overlay starting 20:52.2 into the video, 1080p29.97, QuickTime Animation with alpha
python3 render.py --tline data/bb.tline --shw data/bb.shw --start 20:52.2 --duration 60 --out out/overlay.mov

# add a burned-in preview on the program video
python3 render.py ... --burn-in data/bb.mp4 --burn-out out/preview.mp4

# ProRes 4444, or a PNG sequence
python3 render.py ... --codec prores --out out/overlay_prores.mov
python3 render.py ... --codec png --out out/frames
```

Drop the `.mov` on a track above the program video at the same start time. The sync anchor flags (`--anchor-video`, `--anchor-wall`, `--trim`) are the same as the player's, and the defaults are the Banana Bowl values. `--size`, `--fps`, `--scale`, `--opacity`, `--side`, `--show-idle` and `--no-history` control the look.

Speed and size on an M-series Mac at 1080p: about 90 frames per second, so a 4 h show renders in roughly 70 min. The Animation codec stays around 4 MB per 10 s because most of each frame is transparent; ProRes 4444 is roughly 40 MB per 10 s regardless of content.

## What the Timeline records

Per channel, every 100 ms: RSSI for antennas A to D (tenths of a dBm), audio level (dB, 0 = clip), channel quality 0 to 5, battery bars 0 to 5, battery percent, receiver slot, the receiver's RF level meter 0 to 5, and the ShowLink signal 0 to 5 when an access point is present. Every 4 s the frame also carries the min and max per antenna for the window. A separate event log holds RF dropouts ("No RF Connection"), transmitter on/off, RF power and FD mode changes, each with start and end times to the millisecond. The file layout is documented at the top of `tline.py`.

Timestamps in the file are local wall-clock time stored as if they were UTC. WWB labels them "UTC" in its own display. The tools here treat them as wall-clock and never convert time zones.

## Sync

Both sides carry absolute wall-clock anchors: the WWB recording start time, and for a YouTube live stream the live-start timestamp from the metadata. That gets within seconds. The last step is one human-set anchor (a countdown hitting zero, a visible mic switch-on) plus a trim of a few tenths. For the Banana Bowl: the on-screen countdown reaches 0:00 at 4:52.2 into the VOD, which was 18:30:00 wall-clock.

## Still open

- Payload bytes 14, 15, 17 and 18 only carry data when a ShowLink access point is present; their meaning (transmitter gain, offset, RF power index) is a guess from one recording.
- "Interference" events from the WWB UI have not been seen in a file yet.
- Future shows: the receivers can stream the same metering over Shure's TCP command protocol with real timestamps, which would make the `.tline` decoder a fallback rather than the main path.
