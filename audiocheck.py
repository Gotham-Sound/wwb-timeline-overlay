#!/usr/bin/env python3
"""
audiocheck.py: sanity-check the WWB audio meter against the program audio of a video segment.

Takes mono float32 PCM of the segment (ffmpeg -f f32le), windows it into the Timeline's 100 ms
steps, and correlates the dBFS envelope with the receiver audio level of the loudest live mic.
Also sweeps the lag, which doubles as an independent check of the video/telemetry sync.

  ffmpeg -ss 9353 -t 120 -i video.mp4 -vn -ac 1 -ar 8000 -f f32le seg.f32
  python3 audiocheck.py --tline data/bb.tline --shw data/bb.shw --pcm seg.f32 --rate 8000 \
      --start 2:35:53 --anchor-video 4:52.2 --anchor-wall 18:30:00 --out out/audio_check.png
"""
import argparse
import array
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tline import Timeline, wall_clock, parse_wall_clock  # noqa: E402
from render import parse_video_time  # noqa: E402


def pearson(x, y):
    n = len(x)
    mx, my = sum(x) / n, sum(y) / n
    sxy = sum((a - mx) * (b - my) for a, b in zip(x, y))
    sxx = sum((a - mx) ** 2 for a in x); syy = sum((b - my) ** 2 for b in y)
    return sxy / math.sqrt(sxx * syy) if sxx > 0 and syy > 0 else 0.0


def smooth(v, k):
    out = []
    for i in range(len(v)):
        w = v[max(0, i - k + 1):i + 1]
        out.append(sum(w) / len(w))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tline", required=True); ap.add_argument("--shw")
    ap.add_argument("--pcm", required=True); ap.add_argument("--rate", type=int, default=8000)
    ap.add_argument("--start", required=True); ap.add_argument("--anchor-video", default="4:52.2")
    ap.add_argument("--anchor-wall", default="18:30:00.0"); ap.add_argument("--trim", type=float, default=0)
    ap.add_argument("--out", default="out/audio_check.png")
    ap.add_argument("--max-lag", type=float, default=3.0, help="seconds to sweep each way")
    ap.add_argument("--lag-step", type=int, default=1, help="sweep every Nth window")
    a = ap.parse_args()

    tl = Timeline(a.tline)
    if a.shw: tl.apply_show(a.shw)
    pcm = array.array("f"); pcm.frombytes(open(a.pcm, "rb").read())
    win = a.rate * tl.interval_ms // 1000
    nwin = len(pcm) // win
    prog = []
    for i in range(nwin):
        seg = pcm[i * win:(i + 1) * win]
        rms = math.sqrt(sum(s * s for s in seg) / win)
        prog.append(20 * math.log10(max(rms, 1e-6)))

    anchor_wall = parse_wall_clock(a.anchor_wall, wall_clock(tl.start_ms))
    start = parse_video_time(a.start)
    wall0 = anchor_wall + int((start - parse_video_time(a.anchor_video) + a.trim) * 1000)
    names = {}
    loudest, per_ch = [], {}
    for i in range(nwin):
        fi = tl.frame_at_ms(wall0 + i * tl.interval_ms)
        best = -115
        if fi is not None:
            for s in tl.frame(fi):
                if s.active:
                    best = max(best, s.audio_db)
                    c = tl.by_number.get(s.channel); names[s.channel] = c.name if c else str(s.channel)
                    per_ch.setdefault(s.channel, [-115] * nwin)[i] = s.audio_db
        loudest.append(best)

    print(f"segment: {nwin} windows of {tl.interval_ms} ms from wall {wall_clock(wall0).time()}")
    print(f"program audio dBFS: min {min(prog):.1f} max {max(prog):.1f}   WWB loudest-mic dB: min {min(loudest):.1f} max {max(loudest):.1f}")
    for label, x, y in (("raw 100 ms", prog, loudest), ("500 ms smoothed", smooth(prog, 5), smooth(loudest, 5))):
        best = (0, -2)
        rows = []
        L = int(a.max_lag * 1000 / tl.interval_ms)
        for lag in range(-L, L + 1, a.lag_step):   # lag > 0: telemetry later than audio
            if lag >= 0: xs, ys = x[lag:], y[:len(y) - lag]
            else: xs, ys = x[:lag], y[-lag:]
            if len(xs) < 100: continue       # need at least 10 s of overlap
            r = pearson(xs, ys); rows.append((lag, r))
            if r > best[1]: best = (lag, r)
        r0 = dict(rows)[0]
        top = sorted(rows, key=lambda t: -t[1])[:3]
        print(f"{label}: r at lag 0 = {r0:.3f}; best r = {best[1]:.3f} at lag {best[0] * tl.interval_ms / 1000:+.1f} s; top 3: "
              + ", ".join(f"{r:.2f}@{lag * tl.interval_ms / 1000:+.1f}s" for lag, r in top))
    print("per channel (500 ms smoothed): r at lag 0, and best r over the lag sweep")
    sp = smooth(prog, 5)
    L = int(a.max_lag * 1000 / tl.interval_ms)
    for ch in sorted(per_ch):
        v = per_ch[ch]; act = sum(1 for t in v if t > -115)
        if act < nwin * 0.2: continue
        sv = smooth(v, 5)
        best = (0, -2)
        for lag in range(-L, L + 1, a.lag_step):
            if lag >= 0: xs, ys = sp[lag:], sv[:len(sv) - lag]
            else: xs, ys = sp[:lag], sv[-lag:]
            if len(xs) < 100: continue
            r = pearson(xs, ys)
            if r > best[1]: best = (lag, r)
        print(f"   {names[ch]:8s} active {100 * act // nwin:3d}%  r0 = {pearson(sp, sv):+.3f}  best {best[1]:+.3f} @ {best[0] * tl.interval_ms / 1000:+.1f} s  mean {sum(t for t in v if t > -115) / act:6.1f} dB")

    # chart
    try:
        from PIL import Image, ImageDraw, ImageFont
    except ImportError:
        return
    W, H, L, T = 1800, 620, 70, 30
    img = Image.new("RGB", (W, H), (18, 20, 24)); d = ImageDraw.Draw(img)
    f = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 16) if os.path.exists("/System/Library/Fonts/Helvetica.ttc") else ImageFont.load_default()
    def panel(y0, h, series, color, lo, hi, title):
        d.rectangle((L, y0, W - 20, y0 + h), outline=(60, 64, 72))
        d.text((L, y0 - 22), title, fill=(220, 225, 232), font=f)
        for k in range(0, nwin, 100):
            x = L + (W - 20 - L) * k / nwin
            d.line((x, y0, x, y0 + h), fill=(40, 44, 50)); d.text((x + 2, y0 + h - 18), f"{k // 10}s", fill=(120, 128, 140), font=f)
        pts = [(L + (W - 20 - L) * i / nwin, y0 + h - h * (max(lo, min(hi, v)) - lo) / (hi - lo)) for i, v in enumerate(series)]
        d.line(pts, fill=color, width=2)
        d.text((W - 150, y0 + 4), f"{hi:.0f} dB", fill=(140, 148, 160), font=f); d.text((W - 150, y0 + h - 22), f"{lo:.0f} dB", fill=(140, 148, 160), font=f)
    panel(T + 20, 240, smooth(prog, 3), (159, 211, 255), -45, -5, "Program audio, RMS dBFS per 100 ms (300 ms smoothed)")
    panel(T + 320, 240, smooth(loudest, 3), (57, 211, 83), -70, -10, "WWB audio meter, loudest live mic, dB (300 ms smoothed)")
    img.save(a.out); print("wrote", a.out)


if __name__ == "__main__":
    main()
