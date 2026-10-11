# wwb-overlay

Overlay Shure Wireless Workbench (WWB) Timeline telemetry on show video, in sync.
Proof of concept, started 2026-10-11.

Five parts:

1. `tline.py`: reference decoder for WWB Timeline recorder files (`.tline`). Stdlib only.
2. `shw.py`: pulls receiver model, band, frequency and linked transmitter per channel out of a WWB show file (`.shw`).
3. `player.html`: browser player. Drop a video, a `.tline` and optionally a `.shw` on it, set one sync anchor, and a translucent RF dashboard follows the video.
4. `render.py`: renders that dashboard as an alpha overlay movie for Resolve, or burns it into a preview MP4.
5. `app/`: a native Mac wrapper around the player and renderer (drop files on the window, File > Render Overlay).

## Quick start

Open `player.html` in a browser (double-click works, no server needed), drop the three files on it, and set the anchor: a video time you can identify (for example the moment a countdown hits zero) and the wall-clock time of that moment as WWB shows it. Use the Trim field, or the `,` and `.` keys, to nudge by 0.1 s while watching a mic being switched on.

For a preset session served over HTTP (seekable, shareable on the LAN):

```bash
python3 serve.py
```

then open `http://127.0.0.1:8765/player.html?video=data/bb.mp4&tline=data/bb.tline&shw=data/bb.shw`.
`data/` holds symlinks to the real files and is not committed.

## Mac app

`app/` holds a thin native wrapper: a window hosting the player, Finder drag-and-drop and File > Open for the files, and File > Render Overlay, which runs `render.py` with the player's current anchor and shows progress. Build it with:

```bash
app/build.sh --run
```

That needs Xcode or the command line tools, and produces `build/WWB Overlay.app` (arm64, ad-hoc signed, so it runs on this Mac without Gatekeeper fuss). Rendering from the app still needs `python3`, Pillow and `ffmpeg` on the machine; the app says so if they're missing. Double-clicking a `.tline` or `.shw` can open the app too.

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

Per channel, every 100 ms: RSSI for antennas A to D (tenths of a dBm), audio level (dB, 0 = clip), channel quality 0 to 5, battery bars 0 to 5, battery percent, receiver slot. Every 4 s the frame also carries the min and max per antenna for the window. A separate event log holds RF dropouts ("No RF Connection"), transmitter on/off, RF power and FD mode changes, each with start and end times to the millisecond. The file layout is documented at the top of `tline.py`.

Timestamps in the file are local wall-clock time stored as if they were UTC. WWB labels them "UTC" in its own display. The tools here treat them as wall-clock and never convert time zones.

## Sync

Both sides carry absolute wall-clock anchors: the WWB recording start time, and for a YouTube live stream the live-start timestamp from the metadata. That gets within seconds. The last step is one human-set anchor (a countdown hitting zero, a visible mic switch-on) plus a trim of a few tenths. For the Banana Bowl: the on-screen countdown reaches 0:00 at 4:52.2 into the VOD, which was 18:30:00 wall-clock.

## Still open

- Payload byte 16 is undecoded (moves in steps of 4 while a transmitter is on; probably the front-panel audio LED level). A short calibration recording with a transmitter at known gain and battery would settle it.
- "Interference" events from the WWB UI have not been seen in a file yet.
- Future shows: the receivers can stream the same metering over Shure's TCP command protocol with real timestamps, which would make the `.tline` decoder a fallback rather than the main path.
