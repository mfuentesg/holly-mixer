#!/usr/bin/env python3
"""Records the mixer's RTA and channel levels during a live service and saves them, with the EQ in force.

Read-only: it only subscribes to meters (/meters/4 = RTA, /meters/1 = levels) and reads EQ values. It never
changes the mixer, so it is safe to run during a service.

    python3 xr18_eq_record.py 192.168.1.14 --label ch01 --seconds 60

The RTA shows ONE source at a time (the one chosen in X-AIR-Edit or the official app: a channel, a bus or the
main). So the workflow is one short recording per source:

    1. In X-AIR-Edit pick the RTA source (e.g. channel 1).
    2. Run this with --label ch01 while that channel is in use (speaking, singing, playing).
    3. Repeat for the next channel. Use main / bus1 / ... for the PA and monitors.
    4. python3 xr18_eq_suggest.py eq_sessions/   (analysis and, optionally, AI suggestions)

--label should be the strip key (ch01..ch16, aux, rtn1..rtn4, bus1..bus6, main) so the suggestions can be tied to
that strip; any other text still works as a free label.

Each run writes eq_sessions/session-<label>-<time>.json: the average and peak spectrum (100 bins, only counting
moments with signal), per-channel level statistics, and the EQ settings at that moment.

ASSUMPTION to verify on hardware: the 100 RTA bins are log-spaced from 20 Hz to 20 kHz. Check it once with a known
tone (a 1 kHz tone from a phone should peak near bin 57); the summary prints the peak bin and its frequency.

Python 3.8+, standard library only.
"""

import argparse
import datetime
import json
import math
import pathlib
import select
import struct
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import xr18_dump as dump  # noqa: E402
import xr18_eq_audit as audit  # noqa: E402

RTA_BINS = 100
AXIS = {"type": "log", "min_hz": 20.0, "max_hz": 20000.0, "verified": False}
# /meters/1: 16 mono channels, 5 stereo pairs (aux + 4 FX returns), 6 buses, 4 FX sends, 2 main, 2 monitor.
MAIN_INDEX = (36, 37)


def bin_frequency(index, count=RTA_BINS):
    """Centre frequency of an RTA bin on the assumed log axis."""
    return AXIS["min_hz"] * (AXIS["max_hz"] / AXIS["min_hz"]) ** ((index + 0.5) / count)


def parse(data):
    """(address, args) of one OSC message, keeping blobs as bytes."""
    address, offset = dump._read_string(data, 0)
    if offset >= len(data):
        return address, []
    tags, offset = dump._read_string(data, offset)
    args = []
    for tag in tags[1:]:
        if tag in "if":
            args.append(struct.unpack_from(">i" if tag == "i" else ">f", data, offset)[0])
            offset += 4
        elif tag == "s":
            value, offset = dump._read_string(data, offset)
            args.append(value)
        elif tag == "b":
            size = struct.unpack_from(">i", data, offset)[0]
            offset += 4
            args.append(data[offset:offset + size])
            offset += (size + 3) & ~3
        else:
            break
    return address, args


def meter_values(blob):
    """Little-endian int32 count, then that many little-endian int16 values in 1/256 dB."""
    count = struct.unpack_from("<i", blob, 0)[0]
    count = max(0, min(count, (len(blob) - 4) // 2))
    return [v / 256 for v in struct.unpack_from(f"<{count}h", blob, 4)]


def power(db):
    return 10 ** (db / 10)


def to_db(p):
    return 10 * math.log10(max(p, 1e-13))


class Recorder:
    def __init__(self, rta_gate_db, level_gate_db):
        self.rta_gate = rta_gate_db
        self.level_gate = level_gate_db
        self.rta_frames = 0
        self.rta_active = 0
        self.rta_power = [0.0] * RTA_BINS
        self.rta_peak = [-128.0] * RTA_BINS
        self.level_frames = 0
        self.levels = {}  # name -> {"peak", "power", "active"}

    def add_rta(self, values):
        if len(values) < RTA_BINS:
            return
        values = values[:RTA_BINS]
        self.rta_frames += 1
        if max(values) < self.rta_gate:
            return  # silence: do not dilute the average
        self.rta_active += 1
        for i, v in enumerate(values):
            self.rta_power[i] += power(v)
            self.rta_peak[i] = max(self.rta_peak[i], v)

    def add_levels(self, values):
        if len(values) < 38:
            return
        self.level_frames += 1
        picks = {f"ch{n + 1:02d}": values[n] for n in range(16)}
        picks["main"] = max(values[MAIN_INDEX[0]], values[MAIN_INDEX[1]])
        for key, v in picks.items():
            entry = self.levels.setdefault(key, {"peak": -128.0, "power": 0.0, "active": 0})
            entry["peak"] = max(entry["peak"], v)
            if v >= self.level_gate:
                entry["active"] += 1
                entry["power"] += power(v)

    def result(self):
        n = max(self.rta_active, 1)
        mean = [round(to_db(p / n), 2) for p in self.rta_power]
        levels = {}
        for key, e in self.levels.items():
            active = e["active"]
            levels[key] = {
                "peak_db": round(e["peak"], 1),
                "mean_active_db": round(to_db(e["power"] / active), 1) if active else None,
                "active_pct": round(100 * active / max(self.level_frames, 1), 1),
            }
        return {
            "frames": {"rta": self.rta_frames, "rta_active": self.rta_active, "levels": self.level_frames},
            "rta": {"mean_db": mean, "peak_db": [round(v, 1) for v in self.rta_peak]},
            "levels": levels,
        }


def record(args):
    # 1. EQ in force (a few queries), so the recording is tied to the settings it was made with.
    eq_model, info = {}, None
    if not args.no_eq:
        values, info = audit.read_live(args.host)
        eq_model = audit.build_model(values)

    sock = dump.open_socket(args.host)
    info = info or dump.identify(sock)
    if not info:
        sys.exit(f"No answer from {args.host}:{dump.PORT}. Same network?")

    recorder = Recorder(args.rta_gate, args.level_gate)
    started = time.monotonic()
    end = started + args.seconds if args.seconds else float("inf")
    renewed, shown = 0.0, started
    print(f"Recording '{args.label}' for {'until Ctrl-C' if not args.seconds else f'{args.seconds:.0f} s'}. "
          "Use the sound as in a service.", file=sys.stderr)
    try:
        while time.monotonic() < end:
            now = time.monotonic()
            if now - renewed > 5:  # a meter subscription lasts about 10 s
                sock.send(dump.osc_message("/meters", "/meters/4"))
                sock.send(dump.osc_message("/meters", "/meters/1"))
                renewed = now
            ready, _, _ = select.select([sock], [], [], 0.2)
            if ready:
                try:
                    data = sock.recv(4096)
                except (BlockingIOError, ConnectionRefusedError):
                    continue
                try:
                    address, parts = parse(data)
                    if parts and isinstance(parts[0], (bytes, bytearray)):
                        if address == "/meters/4":
                            recorder.add_rta(meter_values(parts[0]))
                        elif address == "/meters/1":
                            recorder.add_levels(meter_values(parts[0]))
                except (ValueError, struct.error, IndexError):
                    continue
            if now - shown > 5:
                shown = now
                print(f"  {now - started:4.0f} s  RTA frames {recorder.rta_frames} "
                      f"({recorder.rta_active} with signal)", file=sys.stderr)
    except KeyboardInterrupt:
        pass

    result = recorder.result()
    result["meta"] = {
        "label": args.label,
        "taken": datetime.datetime.now().isoformat(timespec="seconds"),
        "seconds": round(time.monotonic() - started, 1),
        "rta_axis": AXIS,
        "rta_gate_db": args.rta_gate,
        "level_gate_db": args.level_gate,
        "note": args.note or "",
        "xinfo": info,
    }
    result["eq"] = eq_model

    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    path = out / f"session-{args.label}-{stamp}.json"
    path.write_text(json.dumps(result, indent=1, ensure_ascii=False))
    summarise(result, path)
    return 0


def summarise(result, path):
    frames = result["frames"]
    print(f"\nSaved {path}")
    print(f"RTA frames: {frames['rta']} ({frames['rta_active']} with signal), level frames: {frames['levels']}")
    if frames["rta_active"] == 0:
        print("No signal reached the RTA. Is the RTA source set to this channel in X-AIR-Edit, and is it playing?")
        return
    mean = result["rta"]["mean_db"]
    peak_bin = max(range(RTA_BINS), key=lambda i: mean[i])
    print(f"Strongest average bin: {peak_bin} (~{bin_frequency(peak_bin):.0f} Hz at {mean[peak_bin]:.1f} dB). "
          "If you played a 1 kHz tone this should be near bin 57; if not, the bin axis assumption is wrong.")
    active = {k: v for k, v in result["levels"].items() if v["active_pct"] >= 5}
    if active:
        print("Channels with signal:")
        for key, v in sorted(active.items()):
            print(f"  {key:<5} peak {v['peak_db']:6.1f} dB   mean {v['mean_active_db']:6.1f} dB   "
                  f"active {v['active_pct']:4.0f}%")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("host", help="mixer IP address")
    parser.add_argument("--label", required=True, help="strip key (ch01, bus3, main) or free text")
    parser.add_argument("--seconds", type=float, default=60, help="how long to record (0 = until Ctrl-C)")
    parser.add_argument("--out", default="eq_sessions", help="folder for the session files")
    parser.add_argument("--note", help="free text saved with the session (e.g. 'sermon, pastor at the pulpit')")
    parser.add_argument("--no-eq", action="store_true", help="do not read the EQ settings")
    parser.add_argument("--rta-gate", type=float, default=-75.0,
                        help="RTA frames whose loudest bin is below this dB are treated as silence")
    parser.add_argument("--level-gate", type=float, default=-55.0,
                        help="channel levels below this dBFS count as 'not active'")
    return record(parser.parse_args())


if __name__ == "__main__":
    sys.exit(main())
