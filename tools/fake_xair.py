#!/usr/bin/env python3
"""A fake Behringer X AIR XR18 that speaks OSC over UDP, for testing Holly Mixer without hardware.

    python3 tools/fake_xair.py                          # listen on 0.0.0.0:10024, church demo data
    python3 tools/fake_xair.py --scenario flaky-wifi
    python3 tools/fake_xair.py --port 10024 --latency-ms 80 --jitter-ms 40 --loss 10

While it runs, type commands on stdin (`help` lists them): `powercycle`, `freeze`, `loss 30`,
`elsewhere ch/03/mix/fader 0.5`, ... See docs/FAKE_MIXER.md.

Python 3.8+, standard library only. Not a real mixer: see "What it does not simulate" in the doc.
"""

import argparse
import heapq
import math
import random
import shlex
import socket
import struct
import sys
import threading
import time

PORT = 10024
XREMOTE_TIMEOUT = 10.0     # seconds a /xremote or /meters subscription lasts
MAX_CLIENTS = 8            # the real mixer serves up to eight /xremote clients
METER_INTERVAL = 0.05      # ~50 ms between meter frames


# --- OSC 1.0 -------------------------------------------------------------------------------

def _pad(data):
    return data + b"\0" * (4 - len(data) % 4)


def _read_string(data, offset):
    end = data.index(b"\0", offset)
    return data[offset:end].decode("utf-8", errors="replace"), (end + 4) & ~3


def osc_encode(address, *args):
    """Encode one OSC message. int -> i, float -> f (float32), str -> s, bytes -> b."""
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
            payload += _pad(arg.encode("utf-8"))
        elif isinstance(arg, (bytes, bytearray)):
            tags += "b"
            payload += struct.pack(">i", len(arg)) + bytes(arg) + b"\0" * (-len(arg) % 4)
        else:
            raise TypeError(f"unsupported OSC argument: {arg!r}")
    return _pad(address.encode("utf-8")) + _pad(tags.encode()) + payload


def _parse_message(data):
    address, offset = _read_string(data, 0)
    if not address.startswith("/"):
        raise ValueError("OSC address must start with /")
    if offset >= len(data):
        return address, []          # an old-style message without a type tag string
    tags, offset = _read_string(data, offset)
    if not tags.startswith(","):
        raise ValueError("bad type tag string")
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
            if size < 0 or offset + size > len(data):
                raise ValueError("bad blob size")
            args.append(bytes(data[offset:offset + size]))
            offset += (size + 3) & ~3
        elif tag == "h":
            args.append(struct.unpack_from(">q", data, offset)[0])
            offset += 8
        elif tag == "d":
            args.append(struct.unpack_from(">d", data, offset)[0])
            offset += 8
        elif tag == "t":
            offset += 8
        elif tag in "TFNI":
            pass                    # no payload; dropped from the argument list
        else:
            raise ValueError(f"unsupported OSC type tag {tag!r}")
    return address, args


def osc_parse(data):
    """Return a list of (address, args). A bundle yields all of its (nested) messages."""
    if data.startswith(b"#bundle\0"):
        out, offset = [], 16
        while offset + 4 <= len(data):
            size = struct.unpack_from(">i", data, offset)[0]
            offset += 4
            if size <= 0 or offset + size > len(data):
                raise ValueError("bad bundle element size")
            out.extend(osc_parse(data[offset:offset + size]))
            offset += size
        return out
    return [_parse_message(data)]


# --- Value mapping (same maths as the app: Mixer.swift / XR18Params.swift) ------------------

def fader_from_db(db):
    if db == float("-inf"):
        return 0.0
    if db >= -10:
        return min((db + 30) / 40, 1.0)
    if db >= -30:
        return (db + 50) / 80
    if db >= -60:
        return (db + 70) / 160
    return max((db + 90) / 480, 0.0)


def normalized(value, lower, upper, log=False):
    low, high = min(lower, upper), max(lower, upper)
    v = min(max(value, low), high)
    if log:
        return math.log(v / lower) / math.log(upper / lower)
    return (v - lower) / (upper - lower)


def _f(x):
    """Round to float32 so a stored value equals what goes over the wire."""
    return struct.unpack(">f", struct.pack(">f", x))[0]


# --- Seed data (church demo from DemoTransport.swift / DemoSeeds.swift) ----------------------

# name, colour, fader dB, on, signal dBFS (or None), pan -1..1, gate, compressor, send to bus 2 (dB)
CHANNELS = [
    ("Pulpito", 3, 7.8, 1, -14, 0, 1, 1, -12),
    ("Mic Oscar", 3, 6.9, 1, -11, -0.1, 1, 1, -8),
    ("Guitarra Acus", 6, 0.7, 1, -19, -0.4, 0, 0, 0),
    ("Bajo", 6, -3.0, 1, -12, 0, 0, 1, 3),
    ("Mic Martin", 3, 7.3, 1, -16, 0.2, 1, 1, -6),
    ("Mic Cata", 3, 6.0, 1, -24, 0.3, 1, 1, -12),
    ("Voz Off", 1, float("-inf"), 0, -60, 0, 0, 0, None),
    ("Guit Marcelo", 6, -8.5, 1, -27, 0.5, 0, 0, -4),
    ("Martín", 6, -1.7, 1, -18, -0.6, 0, 0, -2),
    ("Batería", 6, 0.7, 1, -8, 0, 0, 1, 2),
    ("Maxi", 6, -6.0, 1, -22, 0.35, 0, 0, -5),
] + [("", 0, float("-inf"), 1, None, 0, 0, 0, None)] * 5

BUSES = [("Monitor Pulpito", 5), ("IEM Batería", 4), ("IEM Bajo", 2), ("Wedge Coro", 3), ("Stream", 7), ("Lobby", 0)]
FX_NAMES = ["Hall", "Plate", "Delay", "Chorus"]
DCAS = [("Banda", 6, 0), ("Voces", 3, 2), ("Pastor", 3, 3), ("Playback", 5, -6)]
DCA_MASK = {1: 4, 2: 2, 5: 2, 6: 2, 3: 1, 4: 1, 8: 1, 9: 1, 10: 1, 11: 1}
SNAPSHOT_NAMES = ["Domingo AM", "Domingo PM", "Jóvenes", "Ensayo", "Pasos de sonido"]

# EQ types: 0 low cut, 1 low shelf, 2 parametric, 3 vintage, 4 high shelf, 5 high cut.
# (type, frequency, gain, q)
EQ_VOCAL = (100, [(1, 150, -2, 1), (2, 350, -3, 1.2), (2, 3000, 3, 1), (4, 10000, 2, 1)])
EQ_GUITAR = (80, [(2, 200, -3, 1), (2, 5000, 2, 0.8)])
EQ_BASS = (35, [(2, 80, 3, 1), (2, 800, -3, 1.5)])
EQ_DRUMS = (40, [(2, 400, -4, 1), (4, 8000, 3, 1)])
EQ_FLAT = (None, [])
EQ_MAIN = (None, [(1, 60, 1.5, 1), (2, 250, -1.5, 1), (2, 2500, -1, 1.4), (4, 12000, 1, 1)])
EQ_MONITOR = (None, [(2, 500, -2, 1), (4, 9000, -2, 1)])
EQ_RETURN = (None, [(2, 300, -2, 1), (4, 9000, -1.5, 1)])

# per channel: eq preset, preamp gain dB, dynamics (threshold, ratio index, knee, makeup, attack, release)
CHANNEL_PLAN = [
    (EQ_VOCAL, 24, (-20, 5, 2, 4, 10, 120)), (EQ_VOCAL, 26, (-22, 5, 2, 4, 10, 120)),
    (EQ_GUITAR, 12, None), (EQ_BASS, 10, (-16, 6, 1, 3, 25, 200)),
    (EQ_VOCAL, 25, (-21, 5, 2, 4, 10, 120)), (EQ_VOCAL, 28, (-24, 5, 2, 5, 10, 120)),
    (EQ_VOCAL, 24, None), (EQ_GUITAR, 14, None), (EQ_GUITAR, 12, None),
    (EQ_DRUMS, 18, (-14, 4, 0, 2, 5, 90)), (EQ_GUITAR, 13, None),
] + [(EQ_FLAT, 0, None)] * 5


def _stable_hash(text):
    value = 0
    for ch in text:
        value = (value * 31 + ord(ch)) & 0xFFFF
    return value


def build_state(church=True):
    """The mixer's parameter store. church=True is the demo scene; False is the factory default scene."""
    v = {}

    def eq(base, bands, preset, on):
        low_cut, plan = preset
        v[f"{base}/eq/on"] = 1 if on else 0
        spread = [60, 150, 400, 1000, 3000, 10000] if bands == 6 else [100, 400, 2000, 8000]
        for i in range(bands):
            if i < len(plan):
                kind, freq, gain, q = plan[i]
            else:
                kind, freq, gain, q = (4 if i == bands - 1 else 2), spread[i], 0, 1
            n = i + 1
            v[f"{base}/eq/{n}/type"] = kind
            v[f"{base}/eq/{n}/f"] = _f(normalized(freq, 20, 20000, True))
            v[f"{base}/eq/{n}/g"] = _f(normalized(gain, -15, 15))
            v[f"{base}/eq/{n}/q"] = _f(normalized(q, 10, 0.3, True))
        return low_cut

    def dynamics(base, preset, on, rms=False):
        thr, ratio, knee, makeup, attack, release = preset or (-20, 3, 1, 0, 15, 150)
        if not base.startswith("/ch/"):
            v[f"{base}/dyn/on"] = 1 if on else 0
        v[f"{base}/dyn/mode"] = 0
        v[f"{base}/dyn/det"] = 1 if rms else 0
        v[f"{base}/dyn/env"] = 1
        v[f"{base}/dyn/thr"] = _f(normalized(thr, -60, 0))
        v[f"{base}/dyn/ratio"] = ratio
        v[f"{base}/dyn/knee"] = _f(normalized(knee, 0, 5))
        v[f"{base}/dyn/mgain"] = _f(normalized(makeup, 0, 24))
        v[f"{base}/dyn/attack"] = _f(normalized(attack, 0, 120))
        v[f"{base}/dyn/hold"] = _f(normalized(0.02, 0.02, 2000, True))
        v[f"{base}/dyn/release"] = _f(normalized(release, 5, 4000, True))
        v[f"{base}/dyn/pos"] = 0
        v[f"{base}/dyn/mix"] = _f(1.0)
        v[f"{base}/dyn/auto"] = 0
        v[f"{base}/dyn/keysrc"] = 0
        v[f"{base}/dyn/filter/on"] = 0
        v[f"{base}/dyn/filter/type"] = 0
        v[f"{base}/dyn/filter/f"] = _f(0.5)

    def strip(base, name, color, db, on, sends, pan=0.0):
        v[f"{base}/config/name"] = name if church else ""
        v[f"{base}/config/color"] = color if church else 0
        v[f"{base}/config/icon"] = 1
        v[f"{base}/mix/fader"] = _f(fader_from_db(db if church else 0))
        v[f"{base}/mix/on"] = 1 if (on or not church) else 0
        v[f"{base}/mix/pan"] = _f((pan + 1) / 2 if church else 0.5)
        v[f"{base}/mix/lr"] = 1
        v[f"{base}/grp/dca"] = 0
        v[f"{base}/grp/mute"] = 0
        for n in range(sends):
            level = ((_stable_hash(base) + n * 7) % 21) - 20 if church else None
            v[f"{base}/mix/{n + 1:02d}/level"] = _f(fader_from_db(level)) if church else 0.0
            if n < 6:
                v[f"{base}/mix/{n + 1:02d}/pan"] = _f(0.5)
                v[f"{base}/mix/{n + 1:02d}/grpon"] = 0
                v[f"{base}/mix/{n + 1:02d}/tap"] = 0

    for i, ch in enumerate(CHANNELS):
        n = i + 1
        base = f"/ch/{n:02d}"
        name, color, db, on, _signal, pan, gate, comp, drum = ch
        strip(base, name, color, db, on, 10, pan)
        eq_preset, gain, dyn = CHANNEL_PLAN[i] if church else (EQ_FLAT, 0, None)
        v[f"/headamp/{n:02d}/gain"] = _f(normalized(gain if church else 0, -12, 60))
        v[f"/headamp/{n:02d}/phantom"] = 0
        v[f"{base}/config/insrc"] = i
        v[f"{base}/preamp/rtnsw"] = 0
        v[f"{base}/preamp/invert"] = 0
        low_cut = eq(base, 4, eq_preset, church and n <= 11)
        v[f"{base}/preamp/hpon"] = 0 if low_cut is None else 1
        v[f"{base}/preamp/hpf"] = _f(normalized(low_cut or 80, 20, 400, True))
        is_vocal = church and eq_preset is EQ_VOCAL
        v[f"{base}/gate/on"] = 1 if (church and gate) else 0
        v[f"{base}/gate/mode"] = 3
        v[f"{base}/gate/thr"] = _f(normalized(-52 if is_vocal else -45, -80, 0))
        v[f"{base}/gate/range"] = _f(normalized(20 if is_vocal else 30, 3, 60))
        v[f"{base}/gate/attack"] = _f(normalized(2, 0, 120))
        v[f"{base}/gate/hold"] = _f(normalized(50, 0.02, 2000, True))
        v[f"{base}/gate/release"] = _f(normalized(180, 5, 4000, True))
        v[f"{base}/gate/keysrc"] = 0
        v[f"{base}/gate/filter/on"] = 0
        v[f"{base}/gate/filter/type"] = 0
        v[f"{base}/gate/filter/f"] = _f(0.5)
        dynamics(base, dyn, False)
        v[f"{base}/dyn/on"] = 1 if (church and comp) else 0
        v[f"{base}/insert/on"] = 0
        v[f"{base}/insert/sel"] = 0
        if church:
            v[f"{base}/mix/02/level"] = _f(fader_from_db(drum)) if drum is not None else 0.0
            v[f"{base}/grp/dca"] = DCA_MASK.get(n, 0)
        v[f"/-stat/solosw/{n:02d}"] = 0

    strip("/rtn/aux", "Playback", 7, -10, 1, 10)
    eq("/rtn/aux", 4, EQ_FLAT, True)
    for i, name in enumerate(FX_NAMES):
        strip(f"/rtn/{i + 1}", name, 0, -10, 1, 6)
        eq(f"/rtn/{i + 1}", 4, EQ_RETURN if church else EQ_FLAT, True)
    for i, (name, color) in enumerate(BUSES):
        base = f"/bus/{i + 1}"
        strip(base, name, color, 0, 1, 0)
        eq(base, 6, EQ_MONITOR if (church and i < 3) else EQ_FLAT, church and i < 3)
        dynamics(base, (-12, 4, 1, 0, 20, 250), church and i < 3)
        v[f"{base}/insert/on"] = 0
        v[f"{base}/insert/sel"] = 0
    for i, name in enumerate(FX_NAMES):
        strip(f"/fxsend/{i + 1}", name, 0, 0, 1, 0)
    strip("/lr", "", 0, -1.5, 1, 0)
    eq("/lr", 6, EQ_MAIN if church else EQ_FLAT, True)
    dynamics("/lr", (-8, 3, 2, 0, 30, 300), True, rms=True)
    v["/lr/insert/on"] = 0
    v["/lr/insert/sel"] = 0

    for i, (name, color, db) in enumerate(DCAS):
        base = f"/dca/{i + 1}"
        v[f"{base}/config/name"] = name if church else ""
        v[f"{base}/config/color"] = color if church else 0
        v[f"{base}/fader"] = _f(fader_from_db(db if church else 0))
        v[f"{base}/on"] = 1
    for g in range(1, 5):
        v[f"/config/mute/{g}"] = 0
    for pair in ("1-2", "3-4", "5-6", "7-8", "9-10", "11-12", "13-14", "15-16"):
        v[f"/config/chlink/{pair}"] = 0
    for pair in ("1-2", "3-4", "5-6"):
        v[f"/config/buslink/{pair}"] = 0
    for i in range(1, 5):
        v[f"/fx/{i}/type"] = i - 1
        v[f"/fx/{i}/source"] = 0
    v["/-prefs/name"] = "XR18-C3-D7-F9"
    return {address: [value] for address, value in v.items()}   # every stored value is a list of OSC args


# --- Meters -------------------------------------------------------------------------------

# number of int16 values per /meters/N (X AIR protocol notes)
METER_SIZES = {0: 8, 1: 40, 2: 36, 3: 56, 4: 100, 5: 44, 6: 39, 7: 16, 8: 4, 9: 4}


def _animated(base, t, seed, rng):
    t = t + seed * 1.7
    swell = (math.sin(t * 0.8) + math.sin(t * 2.3 + seed)) / 2
    return base + swell * 8 + rng.uniform(-2, 2)


def meter_levels(meter, t, store, mode, rng):
    """List of dB values (floats) for one meter frame. mode: normal / quiet / loud."""
    n = METER_SIZES[meter]
    shift = {"normal": 0.0, "loud": 14.0, "quiet": -200.0}[mode]
    if meter == 1:
        levels = [-90.0] * 40
        for i, ch in enumerate(CHANNELS):
            if ch[4] is not None:
                levels[i] = _animated(ch[4], t, i, rng) + shift
        levels[16] = _animated(-26, t, 16, rng) + shift
        levels[17] = levels[16] - 1
        for i in range(18, 26):
            levels[i] = _animated(-30, t, i // 2, rng) + shift
        for i in range(26, 36):
            levels[i] = _animated(-18, t, i, rng) + shift
        for i in range(36, 40):
            levels[i] = _animated(-14, t, 40 + i // 2, rng) + shift
        return levels
    if meter == 6:   # gain reduction in negative dB: 16 gates, 16 channel dynamics, 6 buses, main
        red = [0.0] * 39
        if mode == "quiet":
            return red
        for i, ch in enumerate(CHANNELS):
            base = f"/ch/{i + 1:02d}"
            if ch[4] is None:
                continue
            if store.get(f"{base}/gate/on") == [1]:
                red[i] = -max(0.0, _animated(-8, t, i, rng) + 8) * 1.2
            if store.get(f"{base}/dyn/on") == [1]:
                red[16 + i] = -max(0.0, _animated(-4, t, i + 5, rng) + 8) * 0.9
        return red
    base = {0: -30, 2: -35, 3: -40, 4: -60, 5: -28, 7: -50, 8: -45, 9: -70}[meter]
    if mode == "quiet":
        return [-90.0] * n
    return [_animated(base, t, i, rng) + shift for i in range(n)]


def meter_blob(levels, meter):
    """int32 LE count, then int16 LE values in 1/256 dB (gain reduction is clamped to -60)."""
    floor = -60 if meter == 6 else -128
    body = b"".join(struct.pack("<h", int(max(min(x, 0), floor) * 256)) for x in levels)
    return struct.pack("<i", len(levels)) + body


# --- Scenarios ----------------------------------------------------------------------------

SCENARIOS = {
    "normal": {"doc": "well-behaved mixer"},
    "flaky-wifi": {"doc": "15% packet loss, 30 ms latency, up to 80 ms jitter", "loss": 15, "latency_ms": 30, "jitter_ms": 80},
    "slow": {"doc": "400 ms latency plus up to 50 ms jitter", "latency_ms": 400, "jitter_ms": 50},
    "no-xremote": {"doc": "ignores /xremote and /renew: no change is ever pushed", "no_xremote": True},
    "powercycle-after-60s": {"doc": "60 s after start the mixer power-cycles (3 s off, factory settings)", "powercycle_after": 60},
    "wrong-firmware": {"doc": "firmware 1.08: no /snap commands and no /meters/6", "firmware": "1.08"},
    "unreachable": {"doc": "binds the port but never answers", "frozen": True},
}


# --- The fake mixer -----------------------------------------------------------------------

def guess_lan_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("203.0.113.1", 9))     # no packet is sent; this only picks the outgoing interface
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        return "127.0.0.1"


class FakeXAir:
    def __init__(self, host="0.0.0.0", port=PORT, *, latency_ms=0.0, jitter_ms=0.0, loss=0.0, scenario="normal",
                 xremote_timeout=XREMOTE_TIMEOUT, snap_prefix="/snap", name="XR18-C3-D7-F9", ip=None,
                 verbose=False, log=None, seed=None):
        self.rng = random.Random(seed)
        self.xremote_timeout = xremote_timeout
        self.snap_prefix = snap_prefix
        self.name = name
        self.model = "XR18"
        self.firmware = "1.16"
        self.ip = ip or (guess_lan_ip() if host in ("0.0.0.0", "") else host)
        self.verbose = verbose
        self.log = log or (lambda text: print(text, flush=True))

        self.latency_ms = latency_ms
        self.jitter_ms = jitter_ms
        self.loss = loss
        self.frozen = False       # receive and apply, but send nothing
        self.drop = False         # cable pulled: ignore everything in both directions
        self.offline = False      # powered off
        self.no_xremote = False
        self.old_firmware = False
        self.meter_mode = "normal"

        self.lock = threading.RLock()
        self.values = build_state(church=True)
        self.snapshots = {}       # slot -> (name, values, scope)
        initial = {k: (list(a) if isinstance(a, list) else a) for k, a in self.values.items()}
        for slot, snap_name in enumerate(SNAPSHOT_NAMES, 1):
            self.snapshots[slot] = (snap_name, dict(initial), "+" * 59)
        self.snap_index = 1
        self.snap_buffer_name = ""
        self.clients = {}         # addr -> expiry (/xremote)
        self.meter_subs = {}      # (addr, meter) -> expiry
        self.stats = {"rx": 0, "tx": 0, "dropped": 0}
        self.started = time.monotonic()
        self._timers = []
        self._outbox = []         # heap of (due, seq, data, addr)
        self._seq = 0
        self._outbox_cv = threading.Condition()
        self._running = False

        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)
        self.sock.bind((host, port))
        self.sock.settimeout(0.2)
        self.port = self.sock.getsockname()[1]
        self.apply_scenario(scenario)

    # -- lifecycle --

    def start(self):
        self._running = True
        for target in (self._receive_loop, self._meter_loop, self._outbox_loop):
            threading.Thread(target=target, daemon=True).start()
        return self

    def stop(self):
        self._running = False
        for timer in self._timers:
            timer.cancel()
        with self._outbox_cv:
            self._outbox_cv.notify_all()
        time.sleep(0.25)
        try:
            self.sock.close()
        except OSError:
            pass

    # -- scenarios and faults --

    def apply_scenario(self, name):
        if name not in SCENARIOS:
            raise ValueError(f"unknown scenario {name!r}; choose from {', '.join(SCENARIOS)}")
        s = SCENARIOS[name]
        self.scenario = name
        self.latency_ms = s.get("latency_ms", self.latency_ms if name == "normal" else 0)
        self.jitter_ms = s.get("jitter_ms", self.jitter_ms if name == "normal" else 0)
        self.loss = s.get("loss", self.loss if name == "normal" else 0)
        self.frozen = s.get("frozen", False)
        self.no_xremote = s.get("no_xremote", False)
        self.firmware = s.get("firmware", "1.16")
        self.old_firmware = "firmware" in s
        if "powercycle_after" in s:
            self._after(s["powercycle_after"], lambda: self.powercycle(3))

    def _after(self, seconds, fn):
        timer = threading.Timer(seconds, fn)
        timer.daemon = True
        self._timers.append(timer)
        timer.start()

    def powercycle(self, down_seconds=0.0):
        """Switch off (silent for `down_seconds`), then come back with factory settings.

        Like the real XR18, current scene values are lost and every client subscription is gone;
        the 64 snapshot slots live in flash and survive.
        """
        def come_back():
            with self.lock:
                self.values = build_state(church=False)
                self.clients.clear()
                self.meter_subs.clear()
                self.snap_buffer_name = ""
                self.offline = False
            self.log("[fake] back on, factory settings")
        with self.lock:
            self.offline = True
        self.log(f"[fake] power off ({down_seconds:g} s)")
        if down_seconds > 0:
            self._after(down_seconds, come_back)
        else:
            come_back()

    def kick(self):
        with self.lock:
            self.clients.clear()
            self.meter_subs.clear()

    def change_ip(self):
        self.ip = f"192.168.{self.rng.randint(0, 254)}.{self.rng.randint(2, 254)}"
        return self.ip

    def elsewhere(self, address, args):
        """Change a value as if another device did, and tell every subscriber."""
        with self.lock:
            self._store(address, args)
            self._push(address, self.values[address], exclude=None)

    def save_snapshot(self, slot, name=None):
        with self.lock:
            old = self.snapshots.get(slot)
            label = name or self.snap_buffer_name or (old[0] if old else "") or f"Snap {slot}"
            self.snapshots[slot] = (label[:31], self._snapshot_values(), old[2] if old else "+" * 59)
            self.snap_index = slot
            self.snap_buffer_name = ""

    # -- state helpers --

    def _snapshot_values(self):
        return {k: (list(a)) for k, a in self.values.items() if not k.startswith("/-stat")}

    def _store(self, address, args):
        old = self.values.get(address)
        new = list(args)
        if old and len(old) == 1 and len(new) == 1:
            if isinstance(old[0], float) and isinstance(new[0], int):
                new = [float(new[0])]
            elif isinstance(old[0], int) and isinstance(new[0], float):
                new = [int(round(new[0]))]
        new = [_f(a) if isinstance(a, float) else a for a in new]
        self.values[address] = new

    def uptime(self):
        return time.monotonic() - self.started

    # -- output path: loss, latency, jitter --

    def _blocked(self):
        return self.offline or self.drop or self.frozen

    def _emit(self, data, addr):
        if self._blocked():
            return
        if self.loss and self.rng.random() * 100 < self.loss:
            self.stats["dropped"] += 1
            return
        delay = self.latency_ms + (self.rng.uniform(0, self.jitter_ms) if self.jitter_ms else 0)
        if delay <= 0:
            self._send_now(data, addr)
            return
        with self._outbox_cv:
            self._seq += 1
            heapq.heappush(self._outbox, (time.monotonic() + delay / 1000, self._seq, data, addr))
            self._outbox_cv.notify()

    def _send_now(self, data, addr):
        try:
            self.sock.sendto(data, addr)
            self.stats["tx"] += 1
        except OSError:
            pass

    def _outbox_loop(self):
        while self._running:
            with self._outbox_cv:
                if not self._outbox:
                    self._outbox_cv.wait(0.2)
                    continue
                due = self._outbox[0][0]
                now = time.monotonic()
                if due > now:
                    self._outbox_cv.wait(min(due - now, 0.2))
                    continue
                _, _, data, addr = heapq.heappop(self._outbox)
            if not self._blocked():
                self._send_now(data, addr)

    def _reply(self, addr, address, *args):
        self._emit(osc_encode(address, *args), addr)

    def _live_clients(self):
        now = time.monotonic()
        for addr in [a for a, t in self.clients.items() if t <= now]:
            del self.clients[addr]
        return list(self.clients)

    def _push(self, address, args, exclude):
        data = osc_encode(address, *args)
        for client in self._live_clients():
            if client != exclude:
                self._emit(data, client)

    # -- input path --

    def _receive_loop(self):
        while self._running:
            try:
                data, addr = self.sock.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError:
                return
            self.stats["rx"] += 1
            if self.offline or self.drop:
                continue
            if self.loss and self.rng.random() * 100 < self.loss:
                self.stats["dropped"] += 1
                continue
            try:
                messages = osc_parse(data)
            except (ValueError, struct.error, IndexError):
                continue                       # malformed packet: ignored, like the real mixer
            for address, args in messages:
                if self.verbose:
                    self.log(f"[rx] {addr[0]}:{addr[1]} {address} {args}")
                try:
                    with self.lock:
                        self._dispatch(addr, address, args)
                except Exception as error:     # never let one bad packet kill the server
                    self.log(f"[fake] error handling {address}: {error!r}")

    def _dispatch(self, addr, address, args):
        if address in ("/xinfo", "/info", "/status") and not args:
            if address == "/xinfo":
                self._reply(addr, "/xinfo", self.ip, self.name, self.model, self.firmware)
            elif address == "/info":
                self._reply(addr, "/info", "V" + self.firmware, self.name, self.model, self.firmware)
            else:
                self._reply(addr, "/status", "active", self.ip, self.name)
            return
        if address == "/xremote":
            if not self.no_xremote:
                self._subscribe(addr)
            return
        if address == "/renew":
            if not self.no_xremote:
                self._renew(addr, args[0] if args and isinstance(args[0], str) else None)
            return
        if address == "/meters":
            self._meters_request(addr, args)
            return
        if address.startswith(self.snap_prefix + "/") and self._snap(addr, address, args):
            return
        if not args:
            if address in self.values:
                self._reply(addr, address, *self.values[address])
            return
        if address.startswith("/meters/"):
            return                             # meters are read-only
        self._store(address, args)
        self._push(address, self.values[address], exclude=addr)

    def _subscribe(self, addr):
        now = time.monotonic()
        live = self._live_clients()
        if addr not in live and len(live) >= MAX_CLIENTS:
            return
        self.clients[addr] = now + self.xremote_timeout

    def _renew(self, addr, target):
        now = time.monotonic()
        if addr in self.clients or target is None:
            self.clients[addr] = now + self.xremote_timeout
        for key in list(self.meter_subs):
            if key[0] == addr and (target is None or target == f"/meters/{key[1]}"):
                self.meter_subs[key] = now + self.xremote_timeout

    def _meters_request(self, addr, args):
        if not args or not isinstance(args[0], str) or not args[0].startswith("/meters/"):
            return
        try:
            meter = int(args[0].rsplit("/", 1)[1])
        except ValueError:
            return
        if meter not in METER_SIZES or (self.old_firmware and meter == 6):
            return
        live = {k for k, t in self.meter_subs.items() if t > time.monotonic()}
        if (addr, meter) not in live and len({a for a, _ in live} | {addr}) > MAX_CLIENTS:
            return
        self.meter_subs[(addr, meter)] = time.monotonic() + self.xremote_timeout

    # -- snapshots (official protocol: /snap/name, /snap/index, /snap/load|save|delete N, /snap/NN/name|scope) --

    def _snap(self, addr, address, args):
        if self.old_firmware:
            return True                        # old firmware ignores snapshot commands
        parts = address[len(self.snap_prefix) + 1:].split("/")
        head = parts[0]
        if len(parts) == 1:
            if head == "name":
                if args and isinstance(args[0], str):
                    self.snap_buffer_name = args[0][:31]
                else:
                    self._reply(addr, address, self.snap_buffer_name)
                return True
            if head == "index":
                if args and isinstance(args[0], int):
                    self.snap_index = args[0]
                else:
                    self._reply(addr, address, self.snap_index)
                return True
            if head in ("load", "save", "delete") and args and isinstance(args[0], int):
                slot = args[0]
                if 1 <= slot <= 64:
                    getattr(self, "_snap_" + head)(slot)
                return True
            return False
        if len(parts) == 2 and head.isdigit() and parts[1] in ("name", "scope"):
            slot = int(head)
            if not 1 <= slot <= 64:
                return True
            name, values, scope = self.snapshots.get(slot, ("", None, "+" * 59))
            if args:
                if isinstance(args[0], str):
                    if parts[1] == "name":
                        name = args[0][:31]
                    else:
                        scope = args[0][:59]
                    self.snapshots[slot] = (name, values, scope)
                    self._push(address, [args[0][:31] if parts[1] == "name" else scope], exclude=addr)
            else:
                self._reply(addr, address, name if parts[1] == "name" else scope)
            return True
        return False

    def _snap_save(self, slot):
        self.save_snapshot(slot)

    def _snap_delete(self, slot):
        self.snapshots.pop(slot, None)
        if self.snap_index == slot:
            self.snap_index = 0

    def _snap_load(self, slot):
        entry = self.snapshots.get(slot)
        if not entry or entry[1] is None:
            return                              # empty slot: nothing happens
        self.snap_index = slot
        for address, args in entry[1].items():
            if self.values.get(address) != args:
                self.values[address] = list(args)
                self._push(address, args, exclude=None)

    # -- meters --

    def _meter_loop(self):
        while self._running:
            time.sleep(METER_INTERVAL)
            if self._blocked():
                continue
            with self.lock:
                now = time.monotonic()
                for key in [k for k, t in self.meter_subs.items() if t <= now]:
                    del self.meter_subs[key]
                subs = list(self.meter_subs)
                t = self.uptime()
                frames = {}
                for _addr, meter in subs:
                    if meter not in frames:
                        levels = meter_levels(meter, t, self.values, self.meter_mode, self.rng)
                        frames[meter] = osc_encode(f"/meters/{meter}", meter_blob(levels, meter))
            for addr, meter in subs:
                self._emit(frames[meter], addr)

    # -- console --

    def status_text(self):
        with self.lock:
            clients = self._live_clients()
            metered = {k for k, t in self.meter_subs.items() if t > time.monotonic()}
            used = sum(1 for s in self.snapshots.values() if s[1] is not None)
            return "\n".join([
                f"listening on port {self.port}, up {self.uptime():.0f} s, scenario '{self.scenario}'",
                f"model {self.model} firmware {self.firmware} name {self.name} ip {self.ip}",
                f"latency {self.latency_ms:g} ms, jitter {self.jitter_ms:g} ms, loss {self.loss:g}%, "
                f"frozen={self.frozen} drop={self.drop} powered_off={self.offline} meters={self.meter_mode}",
                f"/xremote subscribers: {len(clients)} {[f'{a[0]}:{a[1]}' for a in clients]}",
                f"meter subscriptions: {sorted((m, f'{a[0]}:{a[1]}') for a, m in metered)}",
                f"snapshots stored: {used}/64, last index {self.snap_index}",
                f"packets: rx {self.stats['rx']}, tx {self.stats['tx']}, dropped by loss {self.stats['dropped']}",
            ])

    HELP = """commands:
  status                       show state, subscribers and counters
  drop on|off                  pull the cable: ignore and send nothing
  freeze / resume              keep working but stop replying / reply again
  latency MS | jitter MS | loss PERCENT      network faults on every reply
  powercycle [SECONDS]         switch off (silent), come back with factory settings
  elsewhere ADDRESS VALUE      change a value as another device and push it (e.g. ch/03/mix/fader 0.5)
  get ADDRESS                  print a stored value
  kick                         forget all /xremote and meter subscribers
  changeip                     report a new IP in /xinfo
  quiet | loud | normal        meter levels (silence / hot signal / demo levels)
  snapshot N [NAME]            save the current state to slot N
  scenario NAME                apply a scenario (""" + ", ".join(SCENARIOS) + """)
  help | quit"""

    def command(self, line):
        """Run one console command; returns the text to print."""
        try:
            words = shlex.split(line)
        except ValueError as error:
            return f"cannot parse: {error}"
        if not words:
            return ""
        cmd, rest = words[0].lower(), words[1:]
        try:
            if cmd == "status":
                return self.status_text()
            if cmd == "help":
                return self.HELP
            if cmd == "drop":
                self.drop = rest[0].lower() == "on"
                return f"drop {'on' if self.drop else 'off'}"
            if cmd == "freeze":
                self.frozen = True
                return "frozen: still receiving, no replies"
            if cmd == "resume":
                self.frozen = False
                self.drop = False
                return "replying again"
            if cmd == "latency":
                self.latency_ms = float(rest[0])
                return f"latency {self.latency_ms:g} ms"
            if cmd == "jitter":
                self.jitter_ms = float(rest[0])
                return f"jitter {self.jitter_ms:g} ms"
            if cmd == "loss":
                self.loss = float(rest[0])
                return f"loss {self.loss:g}%"
            if cmd == "powercycle":
                self.powercycle(float(rest[0]) if rest else 0)
                return "power cycle started" if rest else "power cycled: factory settings, subscribers gone"
            if cmd == "elsewhere":
                address = rest[0] if rest[0].startswith("/") else "/" + rest[0]
                args = self._parse_value(address, rest[1:])
                self.elsewhere(address, args)
                return f"{address} = {args} (pushed to subscribers)"
            if cmd == "get":
                address = rest[0] if rest[0].startswith("/") else "/" + rest[0]
                return f"{address} = {self.values.get(address)}"
            if cmd == "kick":
                self.kick()
                return "subscribers forgotten"
            if cmd == "changeip":
                return f"ip is now {self.change_ip()}"
            if cmd in ("quiet", "loud", "normal"):
                self.meter_mode = cmd
                return f"meters {cmd}"
            if cmd == "snapshot":
                slot = int(rest[0])
                if not 1 <= slot <= 64:
                    return "slot must be 1-64"
                self.save_snapshot(slot, " ".join(rest[1:]) or None)
                return f"saved snapshot {slot}"
            if cmd == "scenario":
                self.apply_scenario(rest[0])
                return f"scenario {rest[0]}"
        except (IndexError, ValueError) as error:
            return f"bad arguments ({error}); try 'help'"
        return f"unknown command {cmd!r}; try 'help'"

    def _parse_value(self, address, words):
        if not words:
            raise ValueError("missing value")
        old = self.values.get(address)
        out = []
        for i, word in enumerate(words):
            kind = type(old[i]) if old and i < len(old) else None
            if kind is str:
                out.append(word)
            elif kind is int:
                out.append(int(float(word)))
            elif kind is float:
                out.append(float(word))
            else:
                try:
                    out.append(int(word))
                except ValueError:
                    try:
                        out.append(float(word))
                    except ValueError:
                        out.append(word)
        return out


def main(argv=None):
    parser = argparse.ArgumentParser(description="Fake Behringer X AIR XR18 (OSC over UDP) for testing Holly Mixer.")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=PORT)
    parser.add_argument("--latency-ms", type=float, default=None, help="delay every reply by N ms")
    parser.add_argument("--jitter-ms", type=float, default=None, help="add 0..N ms random delay to every reply")
    parser.add_argument("--loss", type=float, default=None, help="drop PERCENT of packets, in each direction")
    parser.add_argument("--scenario", default="normal", choices=sorted(SCENARIOS))
    parser.add_argument("--ip", default=None, help="IP reported by /xinfo (default: this machine's LAN IP)")
    parser.add_argument("--snap-prefix", default="/snap", choices=["/snap", "/-snap"],
                        help="spelling the snapshot commands answer to")
    parser.add_argument("--xremote-timeout", type=float, default=XREMOTE_TIMEOUT, help="subscription lifetime in seconds")
    parser.add_argument("-v", "--verbose", action="store_true", help="log every received message")
    args = parser.parse_args(argv)

    try:
        mixer = FakeXAir(args.host, args.port, scenario=args.scenario, ip=args.ip, snap_prefix=args.snap_prefix,
                         xremote_timeout=args.xremote_timeout, verbose=args.verbose)
    except OSError as error:
        print(f"cannot bind {args.host}:{args.port}: {error}", file=sys.stderr)
        return 1
    # explicit flags override the scenario's own values
    if args.latency_ms is not None:
        mixer.latency_ms = args.latency_ms
    if args.jitter_ms is not None:
        mixer.jitter_ms = args.jitter_ms
    if args.loss is not None:
        mixer.loss = args.loss
    mixer.start()
    print(f"Fake XR18 listening on {args.host}:{mixer.port} (reports IP {mixer.ip}), scenario '{mixer.scenario}': "
          f"{SCENARIOS[mixer.scenario]['doc']}")
    print("Type 'help' for runtime commands, Ctrl-C to quit.", flush=True)
    try:
        quit_requested = False
        for line in sys.stdin:
            if line.strip().lower() in ("quit", "exit"):
                quit_requested = True
                break
            text = mixer.command(line)
            if text:
                print(text, flush=True)
        while not quit_requested:      # stdin closed (e.g. run in the background): keep serving
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        mixer.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
