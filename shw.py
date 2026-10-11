#!/usr/bin/env python3
"""
shw.py: pull receiver and channel metadata out of a Wireless Workbench show file (.shw, XML).

Returns {device_guid: {name, model, band, serial, channels: {1..4: {name, frequency_khz, audio_gain, tx_name}}}}.
A show file can hold stale devices from earlier shows; match on the device GUID that the
.tline recording references rather than on channel names.
"""
from __future__ import annotations

import sys
import xml.etree.ElementTree as ET


def parse_show(path: str) -> dict:
    root = ET.parse(path).getroot()
    devices = {}
    for dev in root.findall("inventory/device"):
        guid = (dev.findtext("id") or "").strip()
        if not guid:
            continue
        channels = {}
        for ch in dev.findall("channel"):
            num = int(ch.get("number", "0"))
            linked = (ch.findtext("child3_id") or "").strip().lower()
            tx_name = None
            for k in range(1, 9):
                rid = (ch.findtext(f"regtx{k}_id") or "").strip().lower()
                if rid and rid == linked:
                    tx_name = (ch.findtext(f"regtx{k}_name") or "").strip() or None
            freq = ch.findtext("frequency")
            gain = ch.findtext("audio_gain")
            channels[num] = {
                "name": (ch.findtext("channel_name") or "").strip(),
                "frequency_khz": int(freq) if freq else None,
                "audio_gain": int(gain) if gain else None,
                "tx_name": tx_name,
                "registered_tx": [n for n in ((ch.findtext(f"regtx{k}_name") or "").strip() for k in range(1, 9)) if n],
            }
        devices[guid] = {
            "name": (dev.findtext("device_name") or "").strip(),
            "model": (dev.findtext("model") or "").strip(),
            "band": (dev.findtext("band") or "").strip(),
            "serial": (dev.findtext("production_id") or "").strip(),
            "channels": channels,
        }
    return devices


if __name__ == "__main__":
    for guid, d in parse_show(sys.argv[1]).items():
        print(f"{d['model']} {d['band']}  {d['name']:10s} {guid}  sn {d['serial']}")
        for n, c in sorted(d["channels"].items()):
            f = f"{c['frequency_khz'] / 1000:.3f} MHz" if c["frequency_khz"] else "-"
            print(f"   ch {n}: {c['name']:12s} {f:12s} gain {c['audio_gain']}  tx {c['tx_name'] or '-'}  reg {c['registered_tx']}")
