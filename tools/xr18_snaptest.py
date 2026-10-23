#!/usr/bin/env python3
"""Checks that snapshot save, load and delete work on an X AIR mixer, without changing the mix.

It saves the current mix to an EMPTY slot, loads that same slot straight back (the mix it recalls is the one it
just saved, so nothing audible changes), then deletes the slot again. Your own snapshots are never touched.

    python3 xr18_snaptest.py 192.168.1.2              # uses the highest empty slot
    python3 xr18_snaptest.py 192.168.1.2 --slot 60    # uses slot 60 (must be empty)

Only one thing can go wrong: a fader moved by someone in the second between save and load jumps back. Run it
when nobody is touching the mixer. Afterwards the mixer may show the test slot (or none) as the current snapshot.

Python 3.8+, standard library only.
"""

import argparse
import socket
import struct
import sys
import time

PORT = 10024
TEST_NAME = "HM TEST"


def _pad(data: bytes) -> bytes:
    return data + b"\0" * (4 - len(data) % 4)


def osc_message(address: str, *args) -> bytes:
    tags, payload = ",", b""
    for arg in args:
        if isinstance(arg, int):
            tags += "i"
            payload += struct.pack(">i", arg)
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
        else:
            break
    return address, args


class Mixer:
    def __init__(self, host: str):
        self.host = host
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("", 0))
        self.sock.settimeout(0.5)

    def send(self, address: str, *args):
        self.sock.sendto(osc_message(address, *args), (self.host, PORT))

    def query(self, address: str, tries: int = 3):
        for _ in range(tries):
            self.send(address)
            deadline = time.monotonic() + 0.5
            while time.monotonic() < deadline:
                try:
                    data, _ = self.sock.recvfrom(4096)
                except socket.timeout:
                    break
                reply, args = osc_parse(data)
                if reply == address:
                    return args[0] if args else None
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("host", help="mixer IP, e.g. 192.168.1.2")
    parser.add_argument("--slot", type=int, help="empty slot to use (default: the highest empty one)")
    parser.add_argument("--yes", action="store_true", help="don't ask before starting")
    args = parser.parse_args()

    mixer = Mixer(args.host)
    try:
        info = mixer.query("/xinfo")
    except OSError as error:
        print(f"Cannot reach {args.host}: {error}. If iOS asked for Local Network access, allow it and retry.")
        return 1
    if info is None:
        print(f"No reply from {args.host}:{PORT}.")
        return 1

    prefix = next((p for p in ("/-snap", "/snap") if mixer.query(f"{p}/index") is not None), None)
    if prefix is None:
        print("The mixer answers neither /-snap/index nor /snap/index: no snapshot support on this firmware?")
        return 1
    print(f"Snapshot commands answer to {prefix}")

    names = {}
    for slot in range(1, 65):
        name = mixer.query(f"{prefix}/{slot:02d}/name")
        if name is None:
            print(f"Slot {slot} did not answer; try again.")
            return 1
        names[slot] = name
    empty = [slot for slot, name in names.items() if not name]
    slot = args.slot if args.slot else (empty[-1] if empty else None)
    if slot is None:
        print("No empty slot; free one first or pass --slot of an empty one.")
        return 1
    if not 1 <= slot <= 64 or names[slot]:
        print(f"Slot {slot} is not empty ('{names.get(slot, '')}'); pick an empty one.")
        return 1
    start_index = mixer.query(f"{prefix}/index")
    fader_before = mixer.query("/lr/mix/fader")
    print(f"Using empty slot {slot}. Current snapshot: {start_index}.")

    if not args.yes and input("Save, load and delete the test slot now? Type yes: ").strip().lower() not in ("yes", "si", "sí"):
        print("Cancelled; nothing was changed.")
        return 1

    results = []

    def check(label, ok, detail=""):
        results.append(ok)
        print(f"[{'ok' if ok else 'FAIL'}] {label}" + (f"  ({detail})" if detail else ""))

    mixer.send(f"{prefix}/name", TEST_NAME)
    mixer.send(f"{prefix}/save", slot)
    time.sleep(0.6)
    saved_name = mixer.query(f"{prefix}/{slot:02d}/name")
    check(f"save: {prefix}/name + {prefix}/save {slot}", saved_name == TEST_NAME, f"slot name now '{saved_name}'")
    index = mixer.query(f"{prefix}/index")
    check(f"save sets the current snapshot to {slot}", index == slot, f"index {index}")

    mixer.send(f"{prefix}/load", slot)
    time.sleep(0.8)
    index = mixer.query(f"{prefix}/index")
    check(f"load: {prefix}/load {slot}", index == slot, f"index {index}")
    fader_after = mixer.query("/lr/mix/fader")
    check("the mix did not change (main LR fader)", fader_after == fader_before, f"{fader_before} -> {fader_after}")

    mixer.send(f"{prefix}/delete", slot)
    time.sleep(0.6)
    deleted_name = mixer.query(f"{prefix}/{slot:02d}/name")
    check(f"delete: {prefix}/delete {slot}", deleted_name == "", f"slot name now '{deleted_name}'")
    print(f"Current snapshot after the test: {mixer.query(f'{prefix}/index')} (was {start_index}).")

    print("\nAll snapshot commands work." if all(results) else "\nSome checks failed; please share this output.")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
