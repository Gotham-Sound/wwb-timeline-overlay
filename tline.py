#!/usr/bin/env python3
"""
tline.py: reference decoder for Shure Wireless Workbench Timeline recorder files (.tline).

Format (reverse-engineered from WWB 7.9 recordings, verified on two files):

  header      3-byte magic 7A DA 03, then 5 x u64 LE section offsets
  data block  frames, back to back, starting at byte 43
  section 0   recording info: flags byte, interval ms (byte), summary interval ms (u16),
              start time (u64, ms), then per-channel entries (device GUID, slot, channel
              number, channel name, receiver group name)
  section 1   u64 frame count, then u16 byte length of every frame (random-access index)
  section 2   2 bytes, unknown
  section 3   u16 event count, then events: u64 start ms, u64 end ms, three NUL-terminated
              strings (type, channel name, description), 7 trailing bytes (last = channel number)
  section 4   view name and channel display order

  frame       count byte (channels), then per channel: channel number byte + payload(s).
              Normal frame: one 19-byte payload per channel. Every (summary/interval)th frame
              carries three payloads per channel: current, min, max over the window.
  payload     [0-1] RSSI A  [2-3] RSSI B  [4-5] RSSI C  [6-7] RSSI D   int16 LE, tenths of dBm
              (-1100 means antenna not present / floor)
              [8-9]  audio level, int16 LE, dB (0 = clip; -115 = no transmitter)
              [10]   channel quality 0..5, 255 = no transmitter
              [11]   battery bars 0..5 (0 when no transmitter)
              [12]   receiver slot 0..3 (A..D)
              [13]   battery percent, 255 = no transmitter / unknown
              [16]   unknown, changes in steps of 4 while a transmitter is on
              other bytes constant in all samples seen

  Timestamps are LOCAL wall-clock time stored as if it were a UTC epoch (WWB labels them
  "UTC" in its own UI). Treat them as naive wall-clock values; do not convert time zones.

Stdlib only, so it can be bundled into a standalone tool.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import os
import re
import struct
import sys
from dataclasses import dataclass, asdict, field
from typing import Iterator, List, Optional

MAGIC = b"\x7a\xda\x03"
HEADER_LEN = 3 + 8 * 5
PAYLOAD_LEN = 19
NO_TX_AUDIO = -115
NO_TX_BYTE = 255
RSSI_NONE = -1100


def wall_clock(ms: int) -> dt.datetime:
    """Pseudo-UTC epoch ms -> naive wall-clock datetime (what WWB shows on screen)."""
    return dt.datetime(1970, 1, 1) + dt.timedelta(milliseconds=ms)


def parse_wall_clock(s: str, base: dt.datetime) -> int:
    """'HH:MM:SS[.fff]' on the recording's date, or a full ISO datetime -> pseudo-UTC ms."""
    if "T" in s or "-" in s:
        d = dt.datetime.fromisoformat(s)
    else:
        h, m, sec = s.split(":")
        d = base.replace(hour=int(h), minute=int(m), second=0, microsecond=0) + dt.timedelta(seconds=float(sec))
    return int((d - dt.datetime(1970, 1, 1)).total_seconds() * 1000)


@dataclass
class Channel:
    number: int            # channel number used in frames (1-based)
    name: str
    group: str             # receiver group name, e.g. "[RF 1-4]"
    device_id: str         # WWB device GUID (contains Shure OUI 00:0E:DD)
    slot: int              # receiver slot 0..3 (A..D)
    frequency_khz: Optional[int] = None
    model: Optional[str] = None
    band: Optional[str] = None
    device_name: Optional[str] = None
    tx_name: Optional[str] = None
    audio_gain: Optional[int] = None


@dataclass
class Event:
    start_ms: int
    end_ms: int
    type: str
    channel_name: str
    description: str
    channel: int
    tail_hex: str


@dataclass
class Sample:
    channel: int
    rssi: List[float]      # dBm for antennas A..D (None-like RSSI_NONE/10 when absent)
    audio_db: int
    quality: Optional[int]
    bars: Optional[int]
    slot: int
    battery_pct: Optional[int]
    raw16: int
    active: bool


def decode_payload(ch: int, p: bytes) -> Sample:
    a, b, c, d, audio = struct.unpack_from("<hhhhh", p, 0)
    quality = p[10]
    bars = p[11]
    slot = p[12]
    pct = p[13]
    active = quality != NO_TX_BYTE
    return Sample(
        channel=ch,
        rssi=[a / 10, b / 10, c / 10, d / 10],
        audio_db=audio,
        quality=None if quality == NO_TX_BYTE else quality,
        bars=None if not active else bars,
        slot=slot,
        battery_pct=None if pct == NO_TX_BYTE else pct,
        raw16=p[16],
        active=active,
    )


class Timeline:
    def __init__(self, path: str):
        self.path = path
        with open(path, "rb") as f:
            self.data = f.read()
        d = self.data
        if d[:3] != MAGIC:
            raise ValueError(f"not a .tline file (magic {d[:3].hex()})")
        self.offsets = [struct.unpack_from("<Q", d, 3 + 8 * i)[0] for i in range(5)]
        self._parse_info()
        self._parse_index()
        self._parse_events()
        self._parse_view()

    # ---- sections -------------------------------------------------------
    def _parse_info(self):
        s = self.data[self.offsets[0]:self.offsets[1]]
        self.flags = s[0]
        self.interval_ms = s[1]
        self.summary_ms = struct.unpack_from("<H", s, 2)[0]
        self.start_ms = struct.unpack_from("<Q", s, 4)[0]
        pat = re.compile(rb"([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})\x00(.)(.)([^\x00]*)\x00(\[[^\x00]*\])\x00", re.S)
        self.channels: List[Channel] = []
        for m in pat.finditer(s):
            self.channels.append(Channel(
                number=m.group(3)[0],
                name=m.group(4).decode("latin1"),
                group=m.group(5).decode("latin1"),
                device_id=m.group(1).decode("ascii"),
                slot=m.group(2)[0],
            ))
        self.by_number = {c.number: c for c in self.channels}

    def _parse_index(self):
        s = self.data[self.offsets[1]:self.offsets[2]]
        self.frame_count = struct.unpack_from("<Q", s, 0)[0]
        self.frame_lengths = struct.unpack_from(f"<{self.frame_count}H", s, 8)
        offs = [HEADER_LEN]
        for L in self.frame_lengths:
            offs.append(offs[-1] + L)
        self.frame_offsets = offs
        if offs[-1] != self.offsets[0]:
            raise ValueError("frame index does not span the data block")

    def _parse_events(self):
        s = self.data[self.offsets[3]:self.offsets[4]]
        n = struct.unpack_from("<H", s, 0)[0]
        pos = 2
        self.events: List[Event] = []
        for _ in range(n):
            t0, t1 = struct.unpack_from("<QQ", s, pos)
            pos += 16
            strs = []
            for _ in range(3):
                e = s.index(b"\x00", pos)
                strs.append(s[pos:e].decode("latin1"))
                pos = e + 1
            tail = s[pos:pos + 7]
            pos += 7
            if t1 == 0:          # instantaneous events (FD mode, RF power, ...) carry no end time
                t1 = t0
            self.events.append(Event(t0, t1, strs[0], strs[1], strs[2], tail[-1], tail.hex()))
        self.events.sort(key=lambda e: e.start_ms)

    def _parse_view(self):
        s = self.data[self.offsets[4]:]
        m = re.search(rb"([\x20-\x7e]{3,})", s[16:])
        self.view_name = m.group(1).decode("latin1") if m else ""

    # ---- frames ---------------------------------------------------------
    @property
    def end_ms(self) -> int:
        return self.start_ms + self.frame_count * self.interval_ms

    def frame_time_ms(self, i: int) -> int:
        return self.start_ms + i * self.interval_ms

    def frame_at_ms(self, ms: int) -> Optional[int]:
        i = (ms - self.start_ms) // self.interval_ms
        return int(i) if 0 <= i < self.frame_count else None

    def is_summary(self, i: int) -> bool:
        n = self.data[self.frame_offsets[i]]
        return self.frame_lengths[i] == 1 + n * (1 + 3 * PAYLOAD_LEN)

    def frame(self, i: int, which: int = 0) -> List[Sample]:
        """Decode frame i. which: 0 = current, 1 = window min, 2 = window max (summary frames only)."""
        a = self.frame_offsets[i]
        f = self.data[a:a + self.frame_lengths[i]]
        n = f[0]
        per = (len(f) - 1) // n
        npay = (per - 1) // PAYLOAD_LEN
        k = min(which, npay - 1)
        out = []
        pos = 1
        for _ in range(n):
            ch = f[pos]
            p = f[pos + 1 + k * PAYLOAD_LEN: pos + 1 + (k + 1) * PAYLOAD_LEN]
            out.append(decode_payload(ch, p))
            pos += per
        return out

    def iter_frames(self, start: int = 0, stop: Optional[int] = None, step: int = 1) -> Iterator[tuple]:
        stop = self.frame_count if stop is None else min(stop, self.frame_count)
        for i in range(start, stop, step):
            yield i, self.frame_time_ms(i), self.frame(i)

    def events_at(self, ms: int, slack_ms: int = 0) -> List[Event]:
        return [e for e in self.events if e.start_ms - slack_ms <= ms <= max(e.end_ms, e.start_ms) + slack_ms]

    # ---- show file enrichment -----------------------------------------
    def apply_show(self, shw_path: str):
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from shw import parse_show
        devices = parse_show(shw_path)
        for c in self.channels:
            dev = devices.get(c.device_id)
            if not dev:
                continue
            c.model, c.band, c.device_name = dev["model"], dev["band"], dev["name"]
            ch = dev["channels"].get(c.slot + 1)
            if ch:
                c.frequency_khz = ch["frequency_khz"]
                c.tx_name = ch["tx_name"]
                c.audio_gain = ch["audio_gain"]

    # ---- manifest -------------------------------------------------------
    def manifest(self) -> dict:
        return {
            "source": os.path.basename(self.path),
            "view": self.view_name,
            "interval_ms": self.interval_ms,
            "summary_ms": self.summary_ms,
            "start_ms": self.start_ms,
            "end_ms": self.end_ms,
            "start_wall": wall_clock(self.start_ms).isoformat(timespec="milliseconds"),
            "end_wall": wall_clock(self.end_ms).isoformat(timespec="milliseconds"),
            "frame_count": self.frame_count,
            "time_note": "ms values are local wall-clock encoded as a pseudo-UTC epoch (WWB convention)",
            "channels": [asdict(c) for c in self.channels],
            "events": [asdict(e) for e in self.events],
        }


# ---- CLI ------------------------------------------------------------------

def cmd_info(args):
    t = Timeline(args.file)
    if args.shw:
        t.apply_show(args.shw)
    print(f"{t.path}")
    print(f"  view: {t.view_name}   interval: {t.interval_ms} ms   summary every {t.summary_ms} ms")
    print(f"  frames: {t.frame_count}   {wall_clock(t.start_ms)} -> {wall_clock(t.end_ms)}  "
          f"({(t.end_ms - t.start_ms) / 3600000:.2f} h)")
    print(f"  channels ({len(t.channels)}):")
    for c in sorted(t.channels, key=lambda c: c.number):
        extra = ""
        if c.frequency_khz:
            extra = f"  {c.frequency_khz / 1000:.3f} MHz  {c.model or ''} {c.band or ''}  tx={c.tx_name or '-'}"
        print(f"    {c.number:2d}  {c.name:12s} {c.group:12s} slot {'ABCD'[c.slot]}  {c.device_id[:8]}{extra}")
    from collections import Counter
    types = Counter(e.type for e in t.events)
    print(f"  events: {len(t.events)}  {dict(types)}")


def cmd_dump(args):
    t = Timeline(args.file)
    base = wall_clock(t.start_ms)
    ms = parse_wall_clock(args.at, base)
    i = t.frame_at_ms(ms)
    if i is None:
        sys.exit(f"{args.at} is outside the recording ({base.time()} .. {wall_clock(t.end_ms).time()})")
    print(f"frame {i} at {wall_clock(t.frame_time_ms(i))}  summary={t.is_summary(i)}")
    for s in sorted(t.frame(i), key=lambda s: s.channel):
        c = t.by_number.get(s.channel)
        name = c.name if c else "?"
        if s.active or args.all:
            print(f"  {s.channel:2d} {name:10s} A {s.rssi[0]:6.1f}  B {s.rssi[1]:6.1f}  audio {s.audio_db:4d} dB"
                  f"  Q {s.quality if s.quality is not None else '-'}  bars {s.bars if s.bars is not None else '-'}"
                  f"  batt {s.battery_pct if s.battery_pct is not None else '-'}%  raw16 {s.raw16}")
    ev = t.events_at(ms, slack_ms=args.slack * 1000)
    for e in ev:
        print(f"  event {wall_clock(e.start_ms).time()} {e.type} {e.channel_name}: {e.description}")


def cmd_export(args):
    t = Timeline(args.file)
    if args.shw:
        t.apply_show(args.shw)
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "manifest.json"), "w") as f:
        json.dump(t.manifest(), f, indent=1)
    with open(os.path.join(args.out, "events.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["start_wall", "end_wall", "duration_ms", "type", "channel", "channel_name", "description"])
        for e in t.events:
            w.writerow([wall_clock(e.start_ms).isoformat(timespec="milliseconds"),
                        wall_clock(e.end_ms).isoformat(timespec="milliseconds"),
                        e.end_ms - e.start_ms, e.type, e.channel, e.channel_name, e.description])
    n = 0
    with open(os.path.join(args.out, "samples.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["frame", "wall", "channel", "name", "rssi_a", "rssi_b", "rssi_c", "rssi_d",
                    "audio_db", "quality", "bars", "battery_pct", "active"])
        for i, ms, samples in t.iter_frames(step=args.step):
            wall = wall_clock(ms).isoformat(timespec="milliseconds")
            for s in samples:
                if args.active_only and not s.active:
                    continue
                c = t.by_number.get(s.channel)
                w.writerow([i, wall, s.channel, c.name if c else "", *s.rssi, s.audio_db,
                            "" if s.quality is None else s.quality, "" if s.bars is None else s.bars,
                            "" if s.battery_pct is None else s.battery_pct, int(s.active)])
                n += 1
    print(f"wrote {args.out}/manifest.json, events.csv ({len(t.events)} events), samples.csv ({n} rows)")


def main(argv=None):
    ap = argparse.ArgumentParser(description="Decode Shure WWB Timeline (.tline) files")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("info", help="print recording summary"); p.add_argument("file"); p.add_argument("--shw")
    p.set_defaults(fn=cmd_info)
    p = sub.add_parser("dump", help="print one frame at a wall-clock time"); p.add_argument("file")
    p.add_argument("--at", required=True, help="HH:MM:SS[.fff] wall-clock as WWB displays it")
    p.add_argument("--all", action="store_true", help="include idle channels")
    p.add_argument("--slack", type=float, default=0, help="seconds of slack when listing events")
    p.set_defaults(fn=cmd_dump)
    p = sub.add_parser("export", help="write manifest.json, events.csv, samples.csv"); p.add_argument("file")
    p.add_argument("--out", required=True); p.add_argument("--shw")
    p.add_argument("--step", type=int, default=1, help="keep every Nth frame")
    p.add_argument("--active-only", action="store_true", help="skip samples with no transmitter")
    p.set_defaults(fn=cmd_export)
    args = ap.parse_args(argv)
    args.fn(args)


if __name__ == "__main__":
    main()
