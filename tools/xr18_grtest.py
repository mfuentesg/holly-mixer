#!/usr/bin/env python3
"""Watches the gate and compressor gain-reduction meters (/meters/6) of an X AIR mixer. Read-only.

Holly Mixer assumes /meters/6 holds 16 gate, 16 channel compressor, 6 bus compressor and 1 main compressor values,
as int16 in 1/256 dB, negative when the signal is pulled down. This script shows the raw values so that can be
checked: turn a compressor on in a channel that has signal (or lower its threshold) and watch its column.

    python3 xr18_grtest.py 192.168.1.2                 # watch for 30 seconds
    python3 xr18_grtest.py 192.168.1.2 --seconds 60

It only asks for values and meters; it never changes the mixer, so it is safe during a service.

Python 3.8+, standard library only.
"""

import argparse
import socket
import struct
import sys
import time

PORT = 10024


def _pad(data: bytes) -> bytes:
    return data + b"\0" * (4 - len(data) % 4)


def osc_message(address: str, *args) -> bytes:
    tags, payload = ",", b""
    for arg in args:
        tags += "s"
        payload += _pad(arg.encode())
    return _pad(address.encode()) + _pad(tags.encode()) + payload


def _read_string(data: bytes, offset: int):
    end = data.index(b"\0", offset)
    return data[offset:end].decode(errors="replace"), (end + 4) & ~3


def osc_parse(data: bytes):
    address, offset = _read_string(data, 0)
    if offset >= len(data):
        return address, []
    tags, offset = _read_string(data, offset)
    args = []
    for tag in tags[1:]:
        if tag in "if":
            args.append(struct.unpack_from(">i" if tag == "i" else ">f", data, offset)[0])
            offset += 4
        elif tag == "s":
            value, offset = _read_string(data, offset)
            args.append(value)
        elif tag == "b":
            size = struct.unpack_from(">i", data, offset)[0]
            offset += 4
            args.append(data[offset:offset + size])
            offset += (size + 3) & ~3
        else:
            break
    return address, args


def meter_values(blob: bytes):
    """Little-endian int32 count, then that many little-endian int16 values in 1/256 dB."""
    count = struct.unpack_from("<i", blob, 0)[0]
    count = min(count, (len(blob) - 4) // 2)
    return count, [v / 256 for v in struct.unpack_from(f"<{count}h", blob, 4)]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("host", help="mixer IP, e.g. 192.168.1.2")
    parser.add_argument("--seconds", type=float, default=30, help="how long to watch (default 30)")
    args = parser.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("", 0))
    sock.settimeout(0.3)

    def send(address, *values):
        sock.sendto(osc_message(address, *values), (args.host, PORT))

    # Which channels have the gate or the compressor on, and their names.
    queries = []
    for ch in range(1, 17):
        queries += [f"/ch/{ch:02d}/config/name", f"/ch/{ch:02d}/gate/on", f"/ch/{ch:02d}/dyn/on"]
    try:
        for _ in range(2):
            for address in queries:
                send(address)
            deadline = time.monotonic() + 1.0
            state = {}
            while time.monotonic() < deadline and len(state) < len(queries):
                try:
                    data, _ = sock.recvfrom(4096)
                except socket.timeout:
                    continue
                address, values = osc_parse(data)
                if address in queries and values:
                    state[address] = values[0]
            if len(state) == len(queries):
                break
    except OSError as error:
        print(f"Cannot reach {args.host}: {error}. If iOS asked for Local Network access, allow it and retry.")
        return 1
    if not state:
        print(f"No reply from {args.host}:{PORT}.")
        return 1

    names = {ch: state.get(f"/ch/{ch:02d}/config/name") or f"Ch {ch}" for ch in range(1, 17)}
    gate_on = {ch for ch in range(1, 17) if state.get(f"/ch/{ch:02d}/gate/on") == 1}
    dyn_on = {ch for ch in range(1, 17) if state.get(f"/ch/{ch:02d}/dyn/on") == 1}
    print("Compressor on: " + (", ".join(f"{ch} {names[ch]}" for ch in sorted(dyn_on)) or "none"))
    print("Gate on:       " + (", ".join(f"{ch} {names[ch]}" for ch in sorted(gate_on)) or "none"))
    watch = sorted(dyn_on | gate_on) or list(range(1, 17))
    print(f"\nWatching for {args.seconds:.0f} s. Columns per channel: input dBFS / gate GR / comp GR (raw dB).\n")

    lows, highs = [0.0] * 39, [0.0] * 39
    count6, frames, renewed = None, 0, 0.0
    level = [-90.0] * 16
    end = time.monotonic() + args.seconds
    next_print = time.monotonic() + 1
    last6 = [0.0] * 39
    while time.monotonic() < end:
        now = time.monotonic()
        if now - renewed > 5:                      # meter subscriptions last about 10 s
            send("/meters", "/meters/6")
            send("/meters", "/meters/1")
            renewed = now
        try:
            data, _ = sock.recvfrom(4096)
        except socket.timeout:
            data = None
        if data:
            address, values = osc_parse(data)
            if values and isinstance(values[0], bytes) and len(values[0]) >= 4:
                if address == "/meters/6":
                    count6, last6 = meter_values(values[0])
                    frames += 1
                    for i, v in enumerate(last6[:39]):
                        lows[i], highs[i] = min(lows[i], v), max(highs[i], v)
                elif address == "/meters/1":
                    level = meter_values(values[0])[1][:16]
        if now >= next_print:
            next_print = now + 1
            if count6 is None:
                print("  (no /meters/6 yet)")
                continue
            cells = []
            for ch in watch[:6]:
                gate = last6[ch - 1] if ch - 1 < len(last6) else 0
                comp = last6[15 + ch] if 15 + ch < len(last6) else 0
                cells.append(f"{ch}: {level[ch - 1]:5.0f} /{gate:6.1f} /{comp:6.1f}")
            print("  " + "   ".join(cells))

    print()
    if count6 is None:
        print("[FAIL] the mixer never sent /meters/6 (old firmware, or the request format is wrong).")
        return 1
    print(f"/meters/6: {frames} frames, {count6} values each (Holly Mixer expects 39).")
    groups = [("gate", 0, 16), ("comp", 16, 16), ("bus comp", 32, 6), ("main comp", 38, 1)]
    for label, start, size in groups:
        moved = [(i - start + 1, lows[i], highs[i]) for i in range(start, min(start + size, len(lows)))
                 if lows[i] != 0 or highs[i] != 0]
        text = ", ".join(f"{n}: {lo:.1f}..{hi:.1f}" for n, lo, hi in moved) or "no movement"
        print(f"  {label:9} {text}")
    negative = any(v < -0.5 for v in lows)
    positive = any(v > 0.5 for v in highs)
    if negative and not positive:
        print("\nValues go NEGATIVE when reducing: matches what Holly Mixer assumes.")
    elif positive and not negative:
        print("\nValues go POSITIVE when reducing: Holly Mixer needs a fix. Please share this output.")
    elif positive and negative:
        print("\nValues go both ways: please share this output.")
    else:
        print("\nNo gain reduction seen. Lower a compressor threshold on a channel with signal and run it again.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
