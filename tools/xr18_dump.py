#!/usr/bin/env python3
"""Reads everything it can from an X AIR mixer (XR18/XR16/XR12, MR18/MR12) and records what the official app does.

Two modes, both safe: they only send queries and the /xremote subscription, never a change.

    python3 xr18_dump.py dump   192.168.1.2          # read every known parameter into a JSON file
    python3 xr18_dump.py listen 192.168.1.2          # log every change made from any other app (X-AIR-Edit)
    python3 xr18_dump.py --selftest                  # run both against a built-in fake mixer (no hardware)

`dump` answers "what does this mixer hold": values, types, which addresses exist on this firmware and which
ones it ignores. Run it with the mixer in the state you want to keep, then again after a power cycle and
compare the two files with `diff`.

`listen` answers "what does the official app touch": open X-AIR-Edit on the same network, move one control at
a time, and type a note (then Enter) before each one. Every change is logged with its address, value and the
note, and the session ends with the observed range of each parameter. That is how Mixit learns the value
ranges and which address each screen of the official app uses.

Python 3.8+, standard library only.
"""

import argparse
import collections
import datetime
import json
import pathlib
import select
import socket
import struct
import sys
import threading
import time

PORT = 10024


# --- OSC encoding -------------------------------------------------------------

def _pad(data: bytes) -> bytes:
    return data + b"\0" * (4 - len(data) % 4)


def osc_message(address: str, *args) -> bytes:
    tags = ","
    payload = b""
    for arg in args:
        if isinstance(arg, bool):
            raise TypeError("use 0/1 integers")
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
    return data[offset:end].decode(errors="replace"), (end + 4) & ~3


def osc_parse(data: bytes):
    """Return (address, [args]) for one OSC message. Blobs are returned as their length."""
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
            args.append(round(struct.unpack_from(">f", data, offset)[0], 6))
            offset += 4
        elif tag == "s":
            value, offset = _read_string(data, offset)
            args.append(value)
        elif tag == "b":
            size = struct.unpack_from(">i", data, offset)[0]
            offset += 4 + ((size + 3) & ~3)
            args.append({"blob": size})
        else:
            raise ValueError(f"unsupported OSC type tag {tag!r}")
    return address, args


# --- Every address worth asking for ---------------------------------------------

def known_addresses(snapshots: bool = False) -> list:
    """The X AIR parameter tree as documented by Behringer, plus the families seen in X-AIR-Edit 1.8.1.

    The mixer ignores addresses it doesn't have, so extra entries are harmless: they end up in "unanswered".
    """
    out, seen = [], set()

    def add(address):
        if address not in seen:
            seen.add(address)
            out.append(address)

    def dynamics(base, with_key=True):
        for key in ("on", "mode", "det", "env", "thr", "ratio", "knee", "mgain", "attack", "hold",
                    "release", "pos", "mix", "auto") + (("keysrc",) if with_key else ()):
            add(f"{base}/dyn/{key}")
        for key in ("on", "type", "f"):
            add(f"{base}/dyn/filter/{key}")

    def gate(base):
        for key in ("on", "mode", "thr", "range", "attack", "hold", "release", "keysrc"):
            add(f"{base}/gate/{key}")
        for key in ("on", "type", "f"):
            add(f"{base}/gate/filter/{key}")

    def equalizer(base, bands):
        add(f"{base}/eq/on")
        for band in range(1, bands + 1):
            for key in ("type", "f", "g", "q"):
                add(f"{base}/eq/{band}/{key}")

    def mix(base, pan=True):
        for key in ("on", "fader", "lr") + (("pan",) if pan else ()):
            add(f"{base}/mix/{key}")

    def config(base, source=False):
        for key in ("name", "icon", "color") + (("insrc",) if source else ()):
            add(f"{base}/config/{key}")

    def group(base):
        add(f"{base}/grp/dca")
        add(f"{base}/grp/mute")

    def insert(base):
        add(f"{base}/insert/on")
        add(f"{base}/insert/sel")

    def graphic(base):
        for band in range(1, 33):
            add(f"{base}/geq/{band:02d}")

    for number in range(1, 17):
        base = f"/ch/{number:02d}"
        config(base, source=True)
        for key in ("rtnsw", "invert", "hpon", "hpf"):
            add(f"{base}/preamp/{key}")
        gate(base)
        dynamics(base)
        insert(base)
        equalizer(base, 4)
        mix(base)
        for send in range(1, 11):
            add(f"{base}/mix/{send:02d}/level")
            if send <= 6:
                for key in ("pan", "grpon", "tap"):
                    add(f"{base}/mix/{send:02d}/{key}")
        group(base)
        add(f"{base}/automix/group")
        add(f"{base}/automix/weight")
    for base in ["/rtn/aux"] + [f"/rtn/{n}" for n in range(1, 5)]:
        config(base)
        for key in ("rtnsw", "invert"):
            add(f"{base}/preamp/{key}")
        equalizer(base, 4)
        mix(base)
        for send in range(1, 11):
            add(f"{base}/mix/{send:02d}/level")
            if send <= 6:
                for key in ("pan", "grpon", "tap"):
                    add(f"{base}/mix/{send:02d}/{key}")
        group(base)
    for number in range(1, 7):
        base = f"/bus/{number}"
        config(base)
        dynamics(base)
        insert(base)
        equalizer(base, 6)
        graphic(base)
        mix(base)
        group(base)
    for number in range(1, 5):
        base = f"/fxsend/{number}"
        config(base)
        mix(base)
        group(base)
    config("/lr")
    dynamics("/lr")
    insert("/lr")
    equalizer("/lr", 6)
    graphic("/lr")
    mix("/lr")
    for number in range(1, 5):
        base = f"/dca/{number}"
        add(f"{base}/on")
        add(f"{base}/fader")
        config(base)
    for number in range(1, 5):
        add(f"/fx/{number}/type")
        add(f"/fx/{number}/source")
        for param in range(1, 33):
            add(f"/fx/{number}/par/{param:02d}")
    for pair in ("1-2", "3-4", "5-6", "7-8", "9-10", "11-12", "13-14", "15-16"):
        add(f"/config/chlink/{pair}")
    for pair in ("1-2", "3-4", "5-6"):
        add(f"/config/buslink/{pair}")
    for number in range(1, 5):
        add(f"/config/mute/{number}")
    for key in ("hadly", "eq", "dyn", "fdrmute"):
        add(f"/config/linkcfg/{key}")
    for key in ("X", "Y"):
        add(f"/config/amixenable/{key}")
        add(f"/config/amixlock/{key}")
    for key in ("level", "source", "sourcetrim", "chmode", "busmode", "dimatt", "dim", "mono", "mutegrp", "dimpfl"):
        add(f"/config/solo/{key}")
    for key in ("name", "rta/source", "rta/peak", "rta/gain", "lan/addr", "lan/mask", "lan/gateway",
                "ap/ssid", "ap/channel", "is/addr", "is/mask", "is/gateway", "is/ssid"):
        add(f"/-prefs/{key}")
    for number in range(1, 49):
        add(f"/-stat/solosw/{number:02d}")
    for key in ("rta", "tape", "usb"):
        add(f"/-stat/{key}")
    for kind in ("main", "aux", "p16"):
        for number in range(1, 19):
            add(f"/routing/{kind}/{number:02d}")
    for number in range(1, 19):
        add(f"/headamp/{number:02d}/gain")
        add(f"/headamp/{number:02d}/phantom")
    add("/info")
    add("/status")
    if snapshots:
        # Official protocol document: /snap/...; the official app's binary also holds "/-snap", so ask for both.
        for prefix in ("/snap", "/-snap"):
            add(f"{prefix}/index")
            add(f"{prefix}/name")
            for number in range(1, 65):
                add(f"{prefix}/{number:02d}/name")
                add(f"{prefix}/{number:02d}/scope")
    return out


# --- Talking to the mixer --------------------------------------------------------

def open_socket(host: str) -> socket.socket:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.connect((host, PORT))
    sock.setblocking(False)
    return sock


def drain(sock, window: float, sink):
    """Collect every message that arrives in `window` seconds."""
    end = time.monotonic() + window
    while True:
        left = end - time.monotonic()
        if left <= 0:
            return
        ready, _, _ = select.select([sock], [], [], left)
        if not ready:
            return
        try:
            data = sock.recv(4096)
        except (BlockingIOError, ConnectionRefusedError):
            continue
        try:
            sink(*osc_parse(data))
        except (ValueError, struct.error, IndexError):
            continue


def identify(sock, timeout=2.0):
    """Return the /xinfo answer (ip, name, model, firmware) or None."""
    found = []
    for _ in range(3):
        sock.send(osc_message("/xinfo"))
        drain(sock, timeout / 3, lambda a, args: found.append(args) if a == "/xinfo" else None)
        if found:
            return found[0]
    return None


def dump(args) -> int:
    sock = open_socket(args.host)
    info = identify(sock)
    if not info:
        print(f"No answer from {args.host}:{PORT}. Same network? Try xr18_probe.py first.")
        return 1
    print(f"Connected: {info}")
    addresses = known_addresses(args.snapshots)
    if args.extra:
        for line in pathlib.Path(args.extra).read_text().splitlines():
            line = line.strip()
            if line.startswith("/") and line not in addresses:
                addresses.append(line)
    values, pending = {}, list(addresses)

    def keep(address, found):
        if address != "/xinfo" and found:
            values[address] = found

    for attempt in range(1, args.passes + 1):
        sent = 0
        for address in list(pending):
            sock.send(osc_message(address))
            sent += 1
            if sent % 16 == 0:
                drain(sock, 0.01, keep)
        drain(sock, args.wait, keep)
        pending = [a for a in addresses if a not in values]
        print(f"pass {attempt}: {len(values)} answered, {len(pending)} still silent")
        if not pending:
            break

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    name = (info[1] if len(info) > 1 else "xair").replace("/", "_")
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    path = out / f"dump-{name}-{stamp}.json"
    document = {
        "meta": {"host": args.host, "taken": stamp, "xinfo": info, "queried": len(addresses)},
        "values": dict(sorted(values.items())),
        "unanswered": pending,
    }
    path.write_text(json.dumps(document, indent=1, ensure_ascii=False))
    print(f"\nWrote {path}")
    summary = collections.Counter("/".join(a.split("/")[:3]) for a in values)
    print("Answered, by group:")
    for group, count in sorted(summary.items()):
        print(f"  {group:<22}{count}")
    return 0


# --- Watching another app --------------------------------------------------------

def listen(args) -> int:
    sock = open_socket(args.host)
    info = identify(sock)
    if not info:
        print(f"No answer from {args.host}:{PORT}.")
        return 1
    print(f"Connected: {info}")
    print("Subscribed. Use the official app now. Type a note and press Enter before each control you move.")
    print("Press Ctrl-C to finish.\n")
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    log_path = out / f"listen-{stamp}.jsonl"
    log = open(log_path, "w")
    note = {"text": ""}
    seen = collections.defaultdict(lambda: {"count": 0, "min": None, "max": None, "values": set(), "notes": set()})
    start = time.monotonic()

    def reader():
        for line in sys.stdin:
            note["text"] = line.strip()
            log.write(json.dumps({"t": round(time.monotonic() - start, 3), "note": note["text"]}) + "\n")
            log.flush()
            print(f"  [note] {note['text']}")

    threading.Thread(target=reader, daemon=True).start()

    def record(address, values):
        if address.startswith("/meters") or address == "/xinfo":
            return
        entry = seen[address]
        entry["count"] += 1
        if note["text"]:
            entry["notes"].add(note["text"])
        first = values[0] if values else None
        if isinstance(first, (int, float)):
            entry["min"] = first if entry["min"] is None else min(entry["min"], first)
            entry["max"] = first if entry["max"] is None else max(entry["max"], first)
        if len(entry["values"]) < 12:
            entry["values"].add(json.dumps(first))
        log.write(json.dumps({"t": round(time.monotonic() - start, 3), "address": address,
                              "args": values, "note": note["text"]}, ensure_ascii=False) + "\n")
        log.flush()
        print(f"{address:<40} {values}")

    last_renew = 0.0
    try:
        while True:
            if time.monotonic() - last_renew > 8:
                sock.send(osc_message("/xremote"))
                last_renew = time.monotonic()
            drain(sock, 0.25, record)
    except KeyboardInterrupt:
        pass
    log.close()
    ranges = {a: {"count": e["count"], "min": e["min"], "max": e["max"], "sample_values": sorted(e["values"]),
                  "notes": sorted(e["notes"])} for a, e in sorted(seen.items())}
    ranges_path = out / f"ranges-{stamp}.json"
    ranges_path.write_text(json.dumps(ranges, indent=1, ensure_ascii=False))
    print(f"\n{len(seen)} addresses changed.\nLog:    {log_path}\nRanges: {ranges_path}")
    return 0


# --- Built-in fake mixer for --selftest --------------------------------------------

def selftest() -> int:
    """Runs dump and listen against a tiny fake mixer so the scripts can be checked without hardware."""
    server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    server.bind(("127.0.0.1", 0))
    port = server.getsockname()[1]
    stop = threading.Event()
    known = set(known_addresses())
    clients = set()

    def serve():
        server.settimeout(0.1)
        while not stop.is_set():
            try:
                data, peer = server.recvfrom(4096)
            except socket.timeout:
                continue
            address, args = osc_parse(data)
            if address == "/xinfo":
                server.sendto(osc_message("/xinfo", "127.0.0.1", "FAKE-XR18", "XR18", "1.18"), peer)
            elif address == "/xremote":
                clients.add(peer)
            elif address in known and not args and "/par/3" not in address:
                value = "Name" if address.endswith("/name") else (1 if address.endswith(("/on", "/lr")) else 0.5)
                server.sendto(osc_message(address, value), peer)

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    global PORT
    PORT = port
    import tempfile
    folder = tempfile.mkdtemp(prefix="xair-selftest-")
    ok = dump(argparse.Namespace(host="127.0.0.1", out=folder, passes=2, wait=0.3, extra=None, snapshots=False)) == 0
    document = json.loads(next(pathlib.Path(folder).glob("dump-*.json")).read_text())
    answered, silent = len(document["values"]), len(document["unanswered"])
    print(f"selftest dump: {answered} answered, {silent} silent (the fake mixer ignores /par/3x on purpose)")
    ok = ok and answered > 2000 and 0 < silent < answered
    # change something "from another app" and check that listen sees it
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    def push():
        time.sleep(1.0)
        for peer in list(clients):
            server.sendto(osc_message("/ch/01/mix/fader", 0.75), peer)
            server.sendto(osc_message("/ch/01/mix/fader", 0.25), peer)

    threading.Thread(target=push, daemon=True).start()
    args = argparse.Namespace(host="127.0.0.1", out=folder)
    timer = threading.Timer(2.5, lambda: __import__("_thread").interrupt_main())
    timer.start()
    listen(args)
    timer.cancel()
    ranges = json.loads(next(pathlib.Path(folder).glob("ranges-*.json")).read_text())
    seen = ranges.get("/ch/01/mix/fader", {})
    print(f"selftest listen: /ch/01/mix/fader min={seen.get('min')} max={seen.get('max')}")
    ok = ok and seen.get("min") == 0.25 and seen.get("max") == 0.75
    stop.set()
    sock.close()
    print("SELFTEST " + ("PASSED" if ok else "FAILED"))
    return 0 if ok else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--selftest", action="store_true", help="check the scripts against a fake mixer")
    sub = parser.add_subparsers(dest="mode")
    dump_parser = sub.add_parser("dump", help="read every known parameter into a JSON file")
    dump_parser.add_argument("host")
    dump_parser.add_argument("--out", default="xair-captures")
    dump_parser.add_argument("--passes", type=int, default=3, help="retries for addresses that stay silent")
    dump_parser.add_argument("--wait", type=float, default=0.8, help="seconds to wait for replies after each pass")
    dump_parser.add_argument("--extra", help="text file with more addresses to ask for, one per line")
    dump_parser.add_argument("--snapshots", action="store_true", help="also read the 64 snapshot names")
    listen_parser = sub.add_parser("listen", help="log every change made from another app")
    listen_parser.add_argument("host")
    listen_parser.add_argument("--out", default="xair-captures")
    args = parser.parse_args()
    if args.selftest:
        return selftest()
    if args.mode == "dump":
        return dump(args)
    if args.mode == "listen":
        return listen(args)
    parser.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
