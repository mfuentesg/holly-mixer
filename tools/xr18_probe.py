#!/usr/bin/env python3
"""Read-only connectivity probe for Behringer X AIR mixers (XR18/XR16/XR12, MR18/MR12).

Run it from a laptop joined to the same network as the mixer. It never changes
the mixer: it only sends queries, so it is safe to run during a service.

    python3 xr18_probe.py 192.168.1.2          # probe a known IP
    python3 xr18_probe.py --sweep 192.168.1    # find mixers on 192.168.1.0/24

Python 3.8+, standard library only.
"""

import argparse
import socket
import statistics
import struct
import sys
import time

PORT = 10024


# --- OSC encoding -------------------------------------------------------------

def _pad(data: bytes) -> bytes:
    return data + b"\0" * (4 - len(data) % 4)


def _pad_blob(data: bytes) -> bytes:
    return data + b"\0" * (-len(data) % 4)


def osc_message(address: str, *args) -> bytes:
    tags = ","
    payload = b""
    for arg in args:
        if isinstance(arg, int):
            tags += "i"
            payload += struct.pack(">i", arg)
        elif isinstance(arg, float):
            tags += "f"
            payload += struct.pack(">f", arg)
        elif isinstance(arg, str):
            tags += "s"
            payload += _pad(arg.encode())
        else:
            raise TypeError(f"unsupported OSC argument: {arg!r}")
    return _pad(address.encode()) + _pad(tags.encode()) + payload


def _read_string(data: bytes, offset: int):
    end = data.index(b"\0", offset)
    text = data[offset:end].decode(errors="replace")
    return text, (end + 4) & ~3


def osc_parse(data: bytes):
    """Return (address, [args]) for a single OSC message."""
    address, offset = _read_string(data, 0)
    if offset >= len(data):
        return address, []
    tags, offset = _read_string(data, offset)
    args = []
    for tag in tags[1:]:
        if tag == "i":
            args.append(struct.unpack_from(">i", data, offset)[0])
            offset += 4
        elif tag == "f":
            args.append(struct.unpack_from(">f", data, offset)[0])
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
            raise ValueError(f"unsupported OSC type tag {tag!r}")
    return address, args


# --- Value mapping ------------------------------------------------------------

def fader_to_db(value: float) -> float:
    """X32/X AIR fader taper: float 0..1 -> dB (-inf..+10)."""
    if value >= 0.5:
        return value * 40 - 30
    if value >= 0.25:
        return value * 80 - 50
    if value >= 0.0625:
        return value * 160 - 70
    if value > 0:
        return value * 480 - 90
    return float("-inf")


def format_db(db: float) -> str:
    return "-inf dB" if db == float("-inf") else f"{db:+.1f} dB"


# --- Probe --------------------------------------------------------------------

class Probe:
    def __init__(self, timeout: float = 1.0):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        self.sock.bind(("", 0))
        self.sock.settimeout(timeout)

    def send(self, host: str, address: str, *args):
        self.sock.sendto(osc_message(address, *args), (host, PORT))

    def query(self, host: str, address: str, *args, expect: str = None):
        """Send a message and wait for the reply to `expect` (default: same address)."""
        expect = expect or address
        self.send(host, address, *args)
        deadline = time.monotonic() + self.sock.gettimeout()
        while time.monotonic() < deadline:
            try:
                data, _ = self.sock.recvfrom(4096)
            except socket.timeout:
                break
            reply_address, reply_args = osc_parse(data)
            if reply_address == expect:
                return reply_args
        return None


def sweep(subnet: str):
    probe = Probe(timeout=0.2)
    for host in range(1, 255):
        probe.send(f"{subnet}.{host}", "/xinfo")
    found = {}
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        try:
            data, (ip, _) = probe.sock.recvfrom(4096)
        except socket.timeout:
            continue
        address, args = osc_parse(data)
        if address == "/xinfo":
            found[ip] = args
    if not found:
        print(f"No X AIR mixer answered on {subnet}.0/24.")
        return 1
    for ip, args in sorted(found.items()):
        print(f"{ip}: {' | '.join(map(str, args))}")
    return 0


def run(host: str) -> int:
    probe = Probe()
    ok = True

    def check(label, result):
        nonlocal ok
        print(f"[{'ok' if result is not None else 'FAIL'}] {label}")
        if result is None:
            ok = False
        return result

    info = check("/xinfo (model / firmware)", probe.query(host, "/xinfo"))
    if info is None:
        print(f"\nNo reply from {host}:{PORT}. Check the IP, that this laptop is on the same"
              " network (not a guest Wi-Fi), and that client isolation is off.")
        return 1
    print("      " + " | ".join(map(str, info)))

    status = check("/status", probe.query(host, "/status"))
    if status:
        print("      " + " | ".join(map(str, status)))

    name = check("/ch/01/config/name", probe.query(host, "/ch/01/config/name"))
    fader = check("/ch/01/mix/fader", probe.query(host, "/ch/01/mix/fader"))
    if name is not None and fader is not None:
        print(f"      ch 1 '{name[0]}' fader {format_db(fader_to_db(fader[0]))}")
    main = check("/lr/mix/fader", probe.query(host, "/lr/mix/fader"))
    if main is not None:
        print(f"      main LR fader {format_db(fader_to_db(main[0]))}")

    node = check("/node ch/01/mix (bulk read)", probe.query(host, "/node", "ch/01/mix"))
    if node:
        print(f"      {node[0].strip()}")

    meters = check("/meters/1 subscription", probe.query(host, "/meters", "/meters/1",
                                                         expect="/meters/1"))
    if meters and isinstance(meters[0], bytes) and len(meters[0]) >= 4:
        blob = meters[0]
        count = struct.unpack_from("<i", blob, 0)[0]
        values = struct.unpack_from(f"<{min(count, (len(blob) - 4) // 2)}h", blob, 4)
        levels = " ".join(f"{v / 256:.0f}" for v in values[:16])
        print(f"      {count} meter values; first 16 (dBFS): {levels}")

    rtts = []
    for _ in range(20):
        start = time.monotonic()
        if probe.query(host, "/xinfo") is not None:
            rtts.append((time.monotonic() - start) * 1000)
    lost = 20 - len(rtts)
    if rtts:
        print(f"[ok] latency over 20 pings: median {statistics.median(rtts):.1f} ms,"
              f" max {max(rtts):.1f} ms, lost {lost}")
    else:
        print("[FAIL] latency: all 20 pings lost")
        ok = False

    print("\nAll checks passed." if ok else "\nSome checks failed; please share this output.")
    return 0 if ok else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("host", nargs="?", help="mixer IP, e.g. 192.168.1.2")
    parser.add_argument("--sweep", metavar="SUBNET", help="scan SUBNET.1-254, e.g. 192.168.1")
    args = parser.parse_args()
    if args.sweep:
        return sweep(args.sweep)
    if not args.host:
        parser.error("give the mixer IP or --sweep SUBNET")
    return run(args.host)


if __name__ == "__main__":
    sys.exit(main())
