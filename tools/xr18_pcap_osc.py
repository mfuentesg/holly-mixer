#!/usr/bin/env python3
"""Lists the OSC messages in a network capture of the official X-AIR-Edit talking to a mixer.

Record the capture on the computer that runs X-AIR-Edit (macOS, needs administrator rights):

    sudo tcpdump -i en0 -w xair.pcap udp port 10024      # en0 is usually Wi-Fi; use `ifconfig` to check

Open X-AIR-Edit, connect to the mixer, use one screen at a time, then stop tcpdump with Ctrl-C and run:

    python3 xr18_pcap_osc.py xair.pcap                   # summary of every address and its values
    python3 xr18_pcap_osc.py xair.pcap --writes         # only what the app CHANGES (messages with a value)
    python3 xr18_pcap_osc.py xair.pcap --timeline       # every message in order, with direction and time
    python3 xr18_pcap_osc.py --selftest                 # check the decoder on a synthetic capture

A message sent to the mixer without a value is a query; with a value it is a change. Replies come back from
the mixer's port 10024. This tool only reads the file.

Python 3.8+, standard library only. Reads classic .pcap files (what tcpdump -w writes).
"""

import argparse
import collections
import struct
import sys

PORT = 10024


# --- OSC decoding -------------------------------------------------------------

def _read_string(data: bytes, offset: int):
    end = data.index(b"\0", offset)
    return data[offset:end].decode(errors="replace"), (end + 4) & ~3


def osc_parse(data: bytes):
    address, offset = _read_string(data, 0)
    if not address.startswith("/"):
        raise ValueError("not OSC")
    if offset >= len(data):
        return address, []
    tags, offset = _read_string(data, offset)
    if not tags.startswith(","):
        raise ValueError("not OSC")
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
            args.append(f"<blob {size} bytes>")
        else:
            raise ValueError("unsupported tag")
    return address, args


# --- pcap reading ---------------------------------------------------------------

def read_pcap(path: str):
    """Yield (timestamp, ip_payload_bytes) for every IPv4 packet in a classic pcap file."""
    with open(path, "rb") as handle:
        header = handle.read(24)
        magic = header[:4]
        if magic in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1"):
            endian, nano = "<", magic == b"\x4d\x3c\xb2\xa1"
        elif magic in (b"\xa1\xb2\xc3\xd4", b"\xa1\xb2\x3c\x4d"):
            endian, nano = ">", magic == b"\xa1\xb2\x3c\x4d"
        else:
            raise SystemExit("Not a classic pcap file (pcapng is not supported: capture with tcpdump -w).")
        linktype = struct.unpack(endian + "I", header[20:24])[0]
        base = None
        while True:
            record = handle.read(16)
            if len(record) < 16:
                return
            seconds, fraction, size, _ = struct.unpack(endian + "IIII", record)
            frame = handle.read(size)
            stamp = seconds + fraction / (1e9 if nano else 1e6)
            base = stamp if base is None else base
            payload = _strip_link_layer(frame, linktype)
            if payload is not None:
                yield stamp - base, payload


def _strip_link_layer(frame: bytes, linktype: int):
    if linktype == 1 and len(frame) > 14:          # Ethernet
        ethertype = struct.unpack(">H", frame[12:14])[0]
        offset = 14
        if ethertype == 0x8100 and len(frame) > 18:  # VLAN tag
            ethertype = struct.unpack(">H", frame[16:18])[0]
            offset = 18
        return frame[offset:] if ethertype == 0x0800 else None
    if linktype == 0 and len(frame) > 4:           # BSD loopback
        return frame[4:]
    if linktype in (12, 101):                      # raw IP
        return frame
    if linktype == 113 and len(frame) > 16:        # Linux cooked
        return frame[16:]
    return None


def udp_messages(path: str):
    """Yield (time, source, destination, address, args) for every OSC message on UDP port 10024."""
    for stamp, ip in read_pcap(path):
        if len(ip) < 28 or ip[0] >> 4 != 4 or ip[9] != 17:
            continue
        header = (ip[0] & 15) * 4
        source, destination = socket_ip(ip[12:16]), socket_ip(ip[16:20])
        sport, dport = struct.unpack(">HH", ip[header:header + 4])
        if PORT not in (sport, dport):
            continue
        payload = ip[header + 8:]
        try:
            address, args = osc_parse(payload)
        except (ValueError, struct.error, IndexError):
            continue
        yield stamp, f"{source}:{sport}", f"{destination}:{dport}", address, args


def socket_ip(raw: bytes) -> str:
    return ".".join(str(byte) for byte in raw)


# --- Reports -----------------------------------------------------------------------

def report(path: str, writes_only: bool, timeline: bool) -> int:
    messages = list(udp_messages(path))
    if not messages:
        print("No OSC messages on UDP port 10024 in this file.")
        return 1
    mixer = collections.Counter(dst for _, _, dst, _, _ in messages if dst.endswith(f":{PORT}")).most_common(1)
    mixer_ip = mixer[0][0].rsplit(":", 1)[0] if mixer else None
    if timeline:
        for stamp, source, destination, address, args in messages:
            to_mixer = destination.startswith(f"{mixer_ip}:")
            if writes_only and not (to_mixer and args):
                continue
            arrow = "app -> mixer" if to_mixer else "mixer -> app"
            print(f"{stamp:9.3f}  {arrow}  {address}  {args}")
        return 0
    queries, changes, replies = (collections.Counter() for _ in range(3))
    values = collections.defaultdict(set)
    for _, _, destination, address, args in messages:
        to_mixer = destination.startswith(f"{mixer_ip}:")
        if to_mixer and not args:
            queries[address] += 1
        elif to_mixer:
            changes[address] += 1
            values[address].add(repr(args[0]))
        else:
            replies[address] += 1
    print(f"Mixer: {mixer_ip}   messages: {len(messages)}   "
          f"queries: {sum(queries.values())}   changes: {sum(changes.values())}   replies: {sum(replies.values())}\n")
    print("CHANGES sent by the app (address, times, sample values):")
    for address, count in sorted(changes.items()):
        sample = ", ".join(sorted(values[address])[:6])
        print(f"  {address:<42}{count:>5}   {sample}")
    if not writes_only:
        print("\nQUERIES sent by the app (address, times):")
        for address, count in sorted(queries.items()):
            print(f"  {address:<42}{count:>5}")
    return 0


# --- Self test -------------------------------------------------------------------------

def _osc(address, *args):
    def pad(data):
        return data + b"\0" * (4 - len(data) % 4)
    tags, payload = ",", b""
    for arg in args:
        if isinstance(arg, float):
            tags, payload = tags + "f", payload + struct.pack(">f", arg)
        elif isinstance(arg, int):
            tags, payload = tags + "i", payload + struct.pack(">i", arg)
        else:
            tags, payload = tags + "s", payload + pad(str(arg).encode())
    return pad(address.encode()) + pad(tags.encode()) + payload


def _frame(src_ip, dst_ip, sport, dport, payload):
    udp = struct.pack(">HHHH", sport, dport, 8 + len(payload), 0) + payload
    ip = struct.pack(">BBHHHBBH4s4s", 0x45, 0, 20 + len(udp), 0, 0, 64, 17, 0,
                     bytes(map(int, src_ip.split("."))), bytes(map(int, dst_ip.split("."))))
    return b"\0" * 12 + b"\x08\x00" + ip + udp


def selftest() -> int:
    import os
    import tempfile
    packets = [
        _frame("192.168.1.50", "192.168.1.2", 50000, PORT, _osc("/xremote")),
        _frame("192.168.1.50", "192.168.1.2", 50000, PORT, _osc("/ch/01/mix/fader")),
        _frame("192.168.1.2", "192.168.1.50", PORT, 50000, _osc("/ch/01/mix/fader", 0.7)),
        _frame("192.168.1.50", "192.168.1.2", 50000, PORT, _osc("/ch/01/gate/thr", 0.4)),
        _frame("192.168.1.50", "192.168.1.2", 50000, PORT, _osc("/ch/01/config/name", "Pulpito")),
    ]
    path = os.path.join(tempfile.mkdtemp(prefix="xair-pcap-"), "test.pcap")
    with open(path, "wb") as handle:
        handle.write(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 1))
        for index, frame in enumerate(packets):
            handle.write(struct.pack("<IIII", 100 + index, 0, len(frame), len(frame)) + frame)
    decoded = list(udp_messages(path))
    ok = len(decoded) == 5 and decoded[3][3:] == ("/ch/01/gate/thr", [0.4]) and decoded[4][4] == ["Pulpito"]
    report(path, writes_only=False, timeline=False)
    print("\nSELFTEST " + ("PASSED" if ok else "FAILED"))
    return 0 if ok else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("pcap", nargs="?")
    parser.add_argument("--writes", action="store_true", help="only the changes the app sends")
    parser.add_argument("--timeline", action="store_true", help="every message in order")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        return selftest()
    if not args.pcap:
        parser.print_help()
        return 2
    return report(args.pcap, args.writes, args.timeline)


if __name__ == "__main__":
    sys.exit(main())
