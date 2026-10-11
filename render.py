#!/usr/bin/env python3
"""
render.py: render the WWB RF dashboard as an alpha overlay movie (or PNG sequence) that drops
straight onto the program video in Resolve, or burn it into a preview MP4.

Draws the same panel as player.html (keep the two in step), one output frame per video frame,
sample-and-hold on the 10 Hz telemetry. Frames are piped raw into ffmpeg, so nothing lands on
disk except the output file.

Examples
  # 60 s overlay starting 20:52.2 into the video, 1080p29.97, QuickTime Animation with alpha
  python3 render.py --tline data/bb.tline --shw data/bb.shw --start 20:52.2 --duration 60 \
      --out out/overlay.mov

  # same, plus a burned-in preview on the (low-res) program video
  python3 render.py ... --burn-in data/bb.mp4 --burn-out out/demo.mp4

  # ProRes 4444 instead (bigger files, any NLE), or a PNG sequence
  python3 render.py ... --codec prores --out out/overlay_prores.mov
  python3 render.py ... --codec png --out out/frames

Sync: --anchor-video and --anchor-wall tie one video time to one WWB wall-clock time, exactly
like the player. --trim nudges in seconds.
"""
from __future__ import annotations

import argparse
import datetime as dt
import os
import subprocess
import sys
from fractions import Fraction

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tline import Timeline, wall_clock, parse_wall_clock, Sample  # noqa: E402

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.exit("render.py needs Pillow:  python3 -m pip install pillow")

# ---------------------------------------------------------------- fonts / colours
FONTS = {
    "sans": ["/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/Supplemental/Arial.ttf",
             "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"],
    "mono": ["/System/Library/Fonts/Menlo.ttc", "/System/Library/Fonts/Supplemental/Courier New.ttf",
             "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"],
}
_font_cache = {}


def font(kind: str, size: float, bold: bool = False):
    key = (kind, int(round(size)), bold)
    if key in _font_cache:
        return _font_cache[key]
    f = None
    for path in FONTS[kind]:
        if not os.path.exists(path):
            continue
        try:
            f = ImageFont.truetype(path, key[1], index=1 if (bold and path.endswith(".ttc")) else 0)
            break
        except OSError:
            try:
                f = ImageFont.truetype(path, key[1])
                break
            except OSError:
                continue
    if f is None:
        f = ImageFont.load_default(size=key[1])
    _font_cache[key] = f
    return f


def rgba(hexstr: str, a: int = 255):
    h = hexstr.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), a)


GREEN, YELLOW, RED = rgba("39d353"), rgba("f2c94c"), rgba("ff4d4d")
TEXT, SUBTEXT, DIMTEXT, VALUE = rgba("f2f6fa"), rgba("8fa3b8"), rgba("6b7c8f"), rgba("c9d6e3")
TRACK = (255, 255, 255, 26)
STRIP_BG = (255, 255, 255, 15)


def level_color(dbm):
    return GREEN if dbm > -70 else YELLOW if dbm > -85 else RED


def audio_color(db):
    return RED if db > -6 else YELLOW if db > -18 else GREEN


def fmt_clock(ms: int, frac: bool = True) -> str:
    t = wall_clock(ms)
    s = f"{t.hour:02d}:{t.minute:02d}:{t.second:02d}"
    return s + (f".{t.microsecond // 100000}" if frac else "")


# ---------------------------------------------------------------- panel renderer
class PanelRenderer:
    def __init__(self, tl: Timeline, out_w: int, out_h: int, scale=1.0, opacity=0.85, side="right",
                 show_idle=False, history=True):
        self.tl = tl
        self.out_w, self.out_h = out_w, out_h
        self.sc = scale * (out_w / 1280)
        self.opacity = opacity
        self.side = side
        self.show_idle = show_idle
        self.history = history
        self.by_channel = {}
        for e in tl.events:
            self.by_channel.setdefault(e.channel, []).append(e)
        self.channels = sorted(tl.channels, key=lambda c: c.number)

    # events ---------------------------------------------------------------
    def active_drop(self, ch: int, wall: int):
        lst = self.by_channel.get(ch)
        if not lst:
            return None
        for e in reversed(lst):
            if e.start_ms > wall + 100:
                continue
            if wall <= max(e.end_ms, e.start_ms) + 600 and e.type == "No RF Connection":
                return e
            if e.start_ms < wall - 5000:
                break
        return None

    # drawing --------------------------------------------------------------
    def render(self, frame_index, wall: int) -> Image.Image:
        """Return an RGBA image of the whole output frame (transparent except the panel)."""
        sc = self.sc
        in_range = frame_index is not None and 0 <= frame_index < self.tl.frame_count
        rows = []
        if in_range:
            for s in self.tl.frame(frame_index):
                if s.active or self.show_idle:
                    c = self.tl.by_number.get(s.channel)
                    if c:
                        rows.append((c, s))
            rows.sort(key=lambda r: r[0].number)
        W = int(432 * sc)
        row_h, pad, head_h = 38 * sc, 8 * sc, 24 * sc
        H = int(head_h + pad + max(len(rows), 1) * row_h + pad)
        margin = int(12 * sc)
        x0 = self.out_w - W - margin if self.side == "right" else margin
        y0 = margin

        bg = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ImageDraw.Draw(bg).rounded_rectangle((0, 0, W - 1, H - 1), radius=int(8 * sc),
                                             fill=rgba("0b0f14", int(255 * self.opacity)))
        fg = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        d = ImageDraw.Draw(fg)
        # header
        d.text((pad, 16 * sc), "WIRELESS RF", font=font("sans", 13 * sc, True), fill=rgba("e8eef5"), anchor="ls")
        clock = fmt_clock(wall) if wall is not None else "set anchor"
        d.text((W - pad, 16 * sc), clock, font=font("mono", 12 * sc), fill=rgba("9fb3c8"), anchor="rs")
        d.line((pad, head_h, W - pad, head_h), fill=(255, 255, 255, 30), width=1)

        if not in_range:
            msg = ("Anchor not set" if wall is None else
                   f"No telemetry (recording {fmt_clock(self.tl.start_ms, False)} to {fmt_clock(self.tl.end_ms, False)})")
            d.text((pad, head_h + pad + 22 * sc), msg, font=font("sans", 12 * sc), fill=rgba("8899aa"), anchor="ls")
        elif not rows:
            d.text((pad, head_h + pad + 22 * sc), "No active transmitters", font=font("sans", 12 * sc),
                   fill=rgba("8899aa"), anchor="ls")
        y = head_h + pad
        for c, s in rows:
            if s.active:
                self.draw_row(d, fg, c, s, pad, y, W - 2 * pad, row_h, wall, frame_index)
            else:   # idle rows at 45 % alpha, drawn on their own layer
                layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
                self.draw_row(ImageDraw.Draw(layer), layer, c, s, pad, y, W - 2 * pad, row_h, wall, frame_index)
                layer.putalpha(layer.getchannel("A").point(lambda a: int(a * 0.45)))
                fg.alpha_composite(layer)
            y += row_h
        panel = Image.alpha_composite(bg, fg)
        frame = Image.new("RGBA", (self.out_w, self.out_h), (0, 0, 0, 0))
        frame.alpha_composite(panel, (int(x0), int(y0)))
        return frame

    def draw_row(self, d: ImageDraw.ImageDraw, img: Image.Image, c, s: Sample, x, y, w, h, wall, frame_index):
        sc = self.sc
        ev = self.active_drop(c.number, wall) if s.active else None
        if ev:
            d.rounded_rectangle((x - 4 * sc, y + 1, x + w + 4 * sc, y + h - 2), radius=int(4 * sc), fill=(255, 60, 60, 56))
        # name + frequency / transmitter
        d.text((x, y + 14 * sc), c.name, font=font("sans", 12.5 * sc, True), fill=TEXT, anchor="ls")
        if c.frequency_khz:
            sub = f"{c.frequency_khz / 1000:.3f}" + (f" {c.tx_name}" if c.tx_name else "")
        else:
            sub = c.tx_name or c.group
        d.text((x, y + 27 * sc), sub[:13], font=font("mono", 8.5 * sc), fill=SUBTEXT, anchor="ls")
        # RSSI bars
        bx, bw, bh = x + 78 * sc, 82 * sc, 6 * sc
        for label, v, yy in (("A", s.rssi[0], y + 6 * sc), ("B", s.rssi[1], y + 19 * sc)):
            d.text((bx - 9 * sc, yy + bh), label, font=font("mono", 9 * sc), fill=DIMTEXT, anchor="ls")
            d.rectangle((bx, yy, bx + bw, yy + bh), fill=TRACK)
            f = max(0.0, min(1.0, (v + 120) / 100))
            if f > 0:
                d.rectangle((bx, yy, bx + bw * f, yy + bh), fill=level_color(v) if s.active else rgba("555555"))
            d.text((bx + bw + 24 * sc, yy + bh), f"{v:.0f}", font=font("mono", 9 * sc), fill=VALUE, anchor="rs")
        # quality pips + battery
        qx = x + 200 * sc
        for i in range(5):
            on = s.quality is not None and i < s.quality
            col = (GREEN if s.quality >= 4 else YELLOW if s.quality >= 2 else RED) if on else (255, 255, 255, 30)
            d.rectangle((qx + i * 7 * sc, y + 5 * sc, qx + i * 7 * sc + 5 * sc, y + 12 * sc), fill=col)
        d.rectangle((qx, y + 19 * sc, qx + 34 * sc, y + 25 * sc), fill=TRACK)
        if s.battery_pct is not None:
            col = GREEN if s.battery_pct > 30 else YELLOW if s.battery_pct > 15 else RED
            d.rectangle((qx, y + 19 * sc, qx + 34 * sc * s.battery_pct / 100, y + 25 * sc), fill=col)
            d.text((qx + 37 * sc, y + 25 * sc), f"{s.battery_pct}%", font=font("mono", 9 * sc), fill=VALUE, anchor="ls")
        # RF meter bars (receiver's own 0..5 meter) and ShowLink pips
        mx = x + 266 * sc
        d.text((mx, y + 12 * sc), "RF", font=font("mono", 8.5 * sc), fill=DIMTEXT, anchor="ls")
        for i in range(5):
            on = s.rf_bars is not None and i < s.rf_bars
            col = (GREEN if s.rf_bars >= 4 else YELLOW if s.rf_bars >= 2 else RED) if on else (255, 255, 255, 30)
            px = mx + 14 * sc + i * 7 * sc
            d.rectangle((px, y + 5 * sc, px + 5 * sc, y + 12 * sc), fill=col)
        has_sl = s.showlink is not None
        d.text((mx, y + 25 * sc), "SL", font=font("mono", 8.5 * sc), fill=DIMTEXT if has_sl else (255, 255, 255, 60), anchor="ls")
        for i in range(5):
            on = has_sl and i < s.showlink
            px = mx + 14 * sc + i * 7 * sc
            d.rectangle((px, y + 18 * sc, px + 5 * sc, y + 25 * sc), fill=rgba("9fd3ff") if on else (255, 255, 255, 30 if has_sl else 14))
        # audio meter
        ax, aw = x + 322 * sc, 44 * sc
        d.rectangle((ax, y + 5 * sc, ax + aw, y + 25 * sc), fill=TRACK)
        if s.active:
            f = max(0.0, min(1.0, (s.audio_db + 60) / 60))
            if f > 0:
                d.rectangle((ax, y + 5 * sc, ax + aw * f, y + 25 * sc), fill=audio_color(s.audio_db))
            d.text((ax + 2 * sc, y + 32 * sc), "AUD", font=font("mono", 8.5 * sc), fill=DIMTEXT, anchor="ls")
        # history strip: max(A,B) over the last 20 s with dropout ticks
        if self.history:
            hx, hw, hy, hh = x + 372 * sc, 44 * sc, y + 5 * sc, 20 * sc
            d.rectangle((hx, hy, hx + hw, hy + hh), fill=STRIP_BG)
            n, span = 40, 200
            pts = []
            for k in range(n + 1):
                fi = frame_index - span + round(k * span / n)
                if fi < 0:
                    continue
                v = self.tl.rssi_max(fi, c.number)
                if v is None:
                    continue
                pts.append((hx + hw * k / n, hy + hh * (1 - max(0.0, min(1.0, (v + 120) / 100)))))
            if len(pts) > 1:
                d.line(pts, fill=rgba("9fd3ff") if s.active else rgba("555555"), width=max(1, int(1.2 * sc)))
            d.text((hx + 2 * sc, y + 32 * sc), "RF 20s", font=font("mono", 8.5 * sc), fill=DIMTEXT, anchor="ls")
            t0 = wall - 20000
            for e in reversed(self.by_channel.get(c.number, [])):
                if e.start_ms < t0 - 2000:
                    break
                if e.type != "No RF Connection" or e.start_ms > wall:
                    continue
                px = hx + hw * (e.start_ms - t0) / 20000
                pw = max(1.0, hw * max(e.end_ms - e.start_ms, 100) / 20000)
                d.rectangle((px, hy, px + pw, hy + hh), fill=RED)
        if ev:
            d.text((x + 78 * sc, y + 35 * sc), "RF DROP", font=font("sans", 10 * sc, True), fill=RED, anchor="ls")


# ---------------------------------------------------------------- time helpers
def parse_video_time(s: str) -> float:
    parts = s.strip().split(":")
    sec = 0.0
    for p in parts:
        sec = sec * 60 + float(p)
    return sec


def fps_fraction(s: str) -> Fraction:
    table = {"23.976": Fraction(24000, 1001), "29.97": Fraction(30000, 1001), "59.94": Fraction(60000, 1001)}
    if s in table:
        return table[s]
    if "/" in s:
        a, b = s.split("/")
        return Fraction(int(a), int(b))
    return Fraction(s).limit_denominator(10000)


# ---------------------------------------------------------------- main
def main(argv=None):
    ap = argparse.ArgumentParser(description="Render the WWB RF dashboard as an alpha overlay")
    ap.add_argument("--tline", required=True)
    ap.add_argument("--shw")
    ap.add_argument("--anchor-video", default="4:52.2", help="video time of the sync anchor (m:ss.s or h:mm:ss.s)")
    ap.add_argument("--anchor-wall", default="18:30:00.0", help="WWB wall-clock time of that moment (HH:MM:SS.s)")
    ap.add_argument("--trim", type=float, default=0.0, help="seconds added to the mapping")
    ap.add_argument("--start", required=True, help="video time to start rendering at")
    ap.add_argument("--duration", type=float, required=True, help="seconds to render")
    ap.add_argument("--size", default="1920x1080")
    ap.add_argument("--fps", default="29.97")
    ap.add_argument("--scale", type=float, default=1.0)
    ap.add_argument("--opacity", type=float, default=0.85)
    ap.add_argument("--side", choices=["left", "right"], default="right")
    ap.add_argument("--show-idle", action="store_true")
    ap.add_argument("--no-history", action="store_true")
    ap.add_argument("--codec", choices=["qtrle", "prores", "png"], default="qtrle",
                    help="qtrle = QuickTime Animation (lossless alpha, small for mostly-empty frames), "
                         "prores = ProRes 4444, png = image sequence into --out directory")
    ap.add_argument("--out", required=True, help="output .mov (or directory for --codec png)")
    ap.add_argument("--burn-in", help="program video to composite a preview onto")
    ap.add_argument("--burn-out", help="preview MP4 path (default: next to --out)")
    args = ap.parse_args(argv)

    tl = Timeline(args.tline)
    if args.shw:
        tl.apply_show(args.shw)
    W, H = (int(v) for v in args.size.lower().split("x"))
    fps = fps_fraction(args.fps)
    base = wall_clock(tl.start_ms)
    anchor_wall_ms = parse_wall_clock(args.anchor_wall, base)
    anchor_video = parse_video_time(args.anchor_video)
    start = parse_video_time(args.start)
    n_frames = int(round(args.duration * fps))

    def wall_at(video_t: float) -> int:
        return int(round(anchor_wall_ms + (video_t - anchor_video) * 1000 + args.trim * 1000))

    first, last = wall_at(start), wall_at(start + args.duration)
    print(f"rendering {n_frames} frames @ {float(fps):.3f} fps, {W}x{H}, video {args.start} +{args.duration:g}s "
          f"= wall {fmt_clock(first)} .. {fmt_clock(last)}  (recording {fmt_clock(tl.start_ms, False)} .. {fmt_clock(tl.end_ms, False)})")

    rend = PanelRenderer(tl, W, H, scale=args.scale, opacity=args.opacity, side=args.side,
                         show_idle=args.show_idle, history=not args.no_history)

    if args.codec == "png":
        os.makedirs(args.out, exist_ok=True)
        proc = None
    else:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        enc = (["-c:v", "qtrle", "-pix_fmt", "argb"] if args.codec == "qtrle"
               else ["-c:v", "prores_ks", "-profile:v", "4444", "-pix_fmt", "yuva444p10le", "-vendor", "apl0"])
        cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
               "-f", "rawvideo", "-pix_fmt", "rgba", "-s", f"{W}x{H}", "-r", str(fps), "-i", "-",
               *enc, "-r", str(fps), args.out]
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)

    cache_key, cache_img = None, None
    for n in range(n_frames):
        t = start + n / fps
        wall = wall_at(t)
        fi = tl.frame_at_ms(wall)
        key = (fi, wall // 100)                   # telemetry frame and clock tenth
        if key != cache_key:
            cache_img = rend.render(fi, wall)
            cache_key = key
        if proc:
            proc.stdin.write(cache_img.tobytes())
        else:
            cache_img.save(os.path.join(args.out, f"overlay_{n:06d}.png"))
        if n % 300 == 0 or n == n_frames - 1:
            print(f"  {n + 1}/{n_frames}  {fmt_clock(wall)}", end="\r", flush=True)
    print()
    if proc:
        proc.stdin.close()
        if proc.wait() != 0:
            sys.exit("ffmpeg failed")
    print(f"wrote {args.out}")

    if args.burn_in:
        if args.codec == "png":
            sys.exit("--burn-in needs a movie output (qtrle or prores)")
        out = args.burn_out or os.path.splitext(args.out)[0] + "_preview.mp4"
        cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
               "-ss", f"{start:.3f}", "-t", f"{args.duration:.3f}", "-i", args.burn_in, "-i", args.out,
               "-filter_complex", f"[0:v]scale={W}:{H}:flags=lanczos,setsar=1[v];[v][1:v]overlay=0:0:format=auto:shortest=1[o]",
               "-map", "[o]", "-map", "0:a?", "-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p",
               "-c:a", "aac", "-movflags", "+faststart", out]
        subprocess.run(cmd, check=True)
        print(f"wrote {out}")


if __name__ == "__main__":
    main()
