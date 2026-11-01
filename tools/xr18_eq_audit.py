#!/usr/bin/env python3
"""Reviews the EQ of an X AIR mixer (XR18/XR16/XR12) and says what looks wrong or could be better.

Read-only: it only sends queries, never a change.

    python3 tools/xr18_eq_audit.py 192.168.1.2                 # read the live mixer and print the report
    python3 tools/xr18_eq_audit.py 192.168.1.2 --json eq.json  # also save the EQ in real units (frequency, dB, Q)
    python3 tools/xr18_eq_audit.py --dump dump-XR18-2026.json  # audit a file written by xr18_dump.py (no mixer)
    python3 tools/xr18_eq_audit.py --selftest                  # check the rules against a built-in sample

What it checks (all rules are rules of thumb, not laws: the report says "look at", not "fix"):
  * EQ off but bands set, EQ on but every band flat
  * low cut missing or in an odd place for what the channel is called (voice, kick, guitar, ...)
  * boosts that are large, stacked on top of each other, or narrow (feedback / ringing risk)
  * bands left at 0 dB, or cut/shelf bands used where the preamp low cut belongs
  * main and monitor buses: total boost, boosts in the feedback zone (1-4 kHz) on monitors
  * channel names that are still the defaults

The `--json` file is also the shape of the data an in-app "AI EQ" would send (see docs/AI_EQ_PROPOSAL.md).

Python 3.8+, standard library only.
"""

import argparse
import json
import math
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import xr18_dump as dump  # noqa: E402  (same folder: OSC encoding and socket helpers)

TYPES = ["low cut", "low shelf", "peak", "vintage", "high shelf", "high cut"]
TAGS = {"low cut": "LC ", "low shelf": "LS ", "peak": "", "vintage": "V ", "high shelf": "HS ", "high cut": "HC "}


# --- Value conversion (same ranges as XR18Params.swift) -----------------------------------

def log_value(n, lower, upper):
    return lower * (upper / lower) ** n


def to_hz(n):
    return log_value(n, 20.0, 20000.0)


def to_db(n):
    return -15.0 + 30.0 * n


def to_q(n):
    return log_value(n, 10.0, 0.3)


def to_lowcut(n):
    return log_value(n, 20.0, 400.0)


def fmt_hz(hz):
    return f"{hz / 1000:.1f} kHz" if hz >= 1000 else f"{hz:.0f} Hz"


def octaves(a, b):
    return abs(math.log2(a / b))


# --- Reading the mixer ------------------------------------------------------------------------

def strips():
    """(key, base address, label, band count, has preamp)"""
    out = [(f"ch{n:02d}", f"/ch/{n:02d}", f"CH {n:02d}", 4, True) for n in range(1, 17)]
    out.append(("aux", "/rtn/aux", "AUX IN", 4, False))
    out += [(f"rtn{n}", f"/rtn/{n}", f"FX RTN {n}", 4, False) for n in range(1, 5)]
    out += [(f"bus{n}", f"/bus/{n}", f"BUS {n}", 6, False) for n in range(1, 7)]
    out.append(("main", "/lr", "MAIN", 6, False))
    return out


def addresses():
    out = []
    for _, base, _, bands, preamp in strips():
        out += [f"{base}/config/name", f"{base}/eq/on"]
        if preamp:
            out += [f"{base}/preamp/hpon", f"{base}/preamp/hpf"]
        for band in range(1, bands + 1):
            out += [f"{base}/eq/{band}/{k}" for k in ("type", "f", "g", "q")]
    return out


def read_live(host):
    sock = dump.open_socket(host)
    info = dump.identify(sock)
    if not info:
        sys.exit(f"No answer from {host}:{dump.PORT}. Same network? Try tools/xr18_probe.py first.")
    print(f"Connected: {info}", file=sys.stderr)
    wanted = addresses()
    values = {}

    def keep(address, args):
        if address != "/xinfo" and args:
            values[address] = args

    pending = list(wanted)
    for attempt in range(1, 6):
        sent = 0
        for address in pending:
            sock.send(dump.osc_message(address))
            sent += 1
            if sent % 16 == 0:
                dump.drain(sock, 0.01, keep)
        dump.drain(sock, 0.5, keep)
        pending = [a for a in wanted if a not in values]
        if not pending:
            break
    if pending:
        print(f"Warning: {len(pending)} of {len(wanted)} values got no answer (re-run, or check Wi-Fi).",
              file=sys.stderr)
    return values, info


def build_model(values):
    """Raw OSC values -> {strip key: {name, eq_on, low_cut, bands[]}} in real units."""
    def first(address, default=None):
        args = values.get(address)
        return args[0] if args else default

    model = {}
    for key, base, label, count, preamp in strips():
        if f"{base}/eq/on" not in values:
            continue
        low_cut = None
        if preamp and first(f"{base}/preamp/hpf") is not None:
            low_cut = {"on": bool(first(f"{base}/preamp/hpon", 0)),
                       "hz": round(to_lowcut(first(f"{base}/preamp/hpf")), 1)}
        bands = []
        for band in range(1, count + 1):
            t = first(f"{base}/eq/{band}/type")
            f, g, q = (first(f"{base}/eq/{band}/{k}") for k in ("f", "g", "q"))
            if None in (t, f, g, q):
                continue
            bands.append({"band": band, "type": TYPES[int(t)] if 0 <= int(t) < 6 else str(t),
                          "hz": round(to_hz(f), 1), "gain_db": round(to_db(g), 2), "q": round(to_q(q), 2)})
        model[key] = {"label": label, "name": (first(f"{base}/config/name", "") or "").strip(),
                      "eq_on": bool(first(f"{base}/eq/on", 0)), "low_cut": low_cut, "bands": bands}
    return model


# --- What each channel is, from its name --------------------------------------------------------

# (category, keywords, sensible low cut range in Hz or None, hint)
CATEGORIES = [
    ("kick", ("kick", "bombo", "bd"), (30, 60), "low end lives at 50-100 Hz; carve 300-500 Hz boxiness, click at 3-5 kHz"),
    ("bass", ("bass", "bajo", "dib"), (30, 50), "keep 60-100 Hz, tame 200-400 Hz mud, a little 700-900 Hz for definition"),
    ("drums", ("snare", "caja", "tom", "hat", "hh", "oh", "over", "drum", "bateria", "batería", "perc"),
     (60, 150), "cut below the fundamental, overheads from 150-250 Hz"),
    ("voice", ("voz", "vox", "vocal", "coro", "lead", "pastor", "predic", "speak", "habla", "lider", "líder",
               "mic", "cantante", "worship", "alab", "pulpito", "púlpito"),
     (80, 140), "cut 200-400 Hz if boxy, presence at 3-5 kHz, a little air above 10 kHz"),
    ("guitar", ("gtr", "guit", "ac.", "acou", "acús", "acus", "elec", "banjo", "uke"), (80, 120),
     "cut mud at 200-300 Hz, presence at 3-5 kHz; keep out of the vocal's 2-4 kHz"),
    ("keys", ("key", "tecl", "piano", "synth", "organ", "órgano", "pad"), (40, 100), "usually needs little EQ"),
    ("playback", ("pb", "track", "play", "laptop", "pc", "ipad", "dvd", "video", "usb", "click", "pista"), None,
     "already mastered: avoid boosts, use a low cut only if it rumbles"),
]


def categorise(name):
    lowered = name.lower()
    for category, words, cut, hint in CATEGORIES:
        if any(word in lowered for word in words):
            return category, cut, hint
    return None, None, None


def is_default_name(label, name):
    if not name:
        return True
    return name.lower().replace(" ", "") in (label.lower().replace(" ", ""), "ch" + label[-2:], f"ch{label[-2:]}")


# --- Rules ---------------------------------------------------------------------------------------

def audit(model):
    findings = []  # (severity 0..2, strip label, text)
    flat_on = []

    def add(level, strip, text):
        findings.append((level, strip, text))

    for key, strip in model.items():
        label = f"{strip['label']}" + (f" «{strip['name']}»" if strip["name"] else "")
        bands = strip["bands"]
        is_channel = key.startswith("ch")
        is_bus = key.startswith("bus")
        active = [b for b in bands if b["type"] not in ("low cut", "high cut") and abs(b["gain_db"]) >= 0.5]
        boosts = [b for b in active if b["gain_db"] > 0]
        category, cut_range, hint = categorise(strip["name"])
        used = bool(active) or (strip["low_cut"] or {}).get("on", False)

        if is_channel and used and is_default_name(strip["label"], strip["name"]):
            add(0, label, "has EQ or a low cut but no name: the AI (and the next engineer) can't tell what it is.")

        if not strip["eq_on"] and active:
            add(1, label, "EQ is OFF but " + str(len(active)) + " band(s) are set; none of it is being heard. "
                          "Turn EQ on or flatten the bands.")
        if strip["eq_on"] and bands and not active:
            flat_on.append(label)

        # Low cut
        lc = strip["low_cut"]
        if lc is not None and lc["on"] and lc["hz"] <= 25 and is_channel:
            add(1, label, f"low cut is ON but at {fmt_hz(lc['hz'])}, the minimum: it filters nothing. "
                          "Set a real frequency or switch it off.")
        if lc is not None and lc["on"] and lc["hz"] > 200 and is_channel:
            add(1, label, f"low cut at {fmt_hz(lc['hz'])} is very high: it thins everything below. Intended?")
        if lc is not None and lc["on"] and lc["hz"] >= 40 and is_channel:
            for b in active:
                if b["type"] in ("peak", "vintage") and b["hz"] < lc["hz"] * 0.8 and abs(b["gain_db"]) >= 3:
                    add(1, label, f"band {b['band']} ({b['gain_db']:+.1f} dB at {fmt_hz(b['hz'])}) sits below the "
                                  f"low cut ({fmt_hz(lc['hz'])}): the filter works against it.")
        for b in boosts:
            if is_channel and b["hz"] < 45 and b["gain_db"] >= 3 and b["type"] in ("peak", "vintage") and \
                    category not in ("kick", "bass"):
                add(1, label, f"band {b['band']} boosts {b['gain_db']:+.1f} dB at {fmt_hz(b['hz'])}: almost only "
                              "rumble there, it eats headroom and the PA hardly reproduces it.")
        for b in active:
            if b["gain_db"] <= -10:
                add(1, label, f"band {b['band']} cuts {b['gain_db']:+.1f} dB at {fmt_hz(b['hz'])}: very deep. "
                              "Often a sign of a mic/placement problem or a cut that belongs on a monitor.")
        if lc is not None and is_channel and category not in (None, "playback"):
            if not lc["on"] and cut_range and category in ("voice", "guitar", "drums", "bass", "keys"):
                add(1, label, f"low cut is off; for {category} something around "
                              f"{cut_range[0]}-{cut_range[1]} Hz usually helps (stage rumble, handling noise, mud).")
            elif lc["on"] and cut_range and not (cut_range[0] * 0.6 <= lc["hz"] <= cut_range[1] * 1.6):
                add(0, label, f"low cut at {fmt_hz(lc['hz'])} is outside the usual {cut_range[0]}-"
                              f"{cut_range[1]} Hz for {category}.")
        elif lc is not None and is_channel and not lc["on"] and category is None and strip["name"]:
            add(0, label, "no low cut. Unless it is a kick/bass/synth, 80-100 Hz is a safe start.")

        # Bands doing the preamp's job
        for b in bands:
            if is_channel and b["type"] == "low cut":
                add(0, label, f"band {b['band']} is a low cut; the preamp low cut (channel page) is the one to "
                              "use, it keeps the EQ band free.")

        # Boosts
        for b in boosts:
            if b["gain_db"] >= 9:
                add(2, label, f"band {b['band']} boosts {b['gain_db']:+.1f} dB at {fmt_hz(b['hz'])}: very large. "
                              "Cutting elsewhere or raising the fader is usually cleaner.")
            elif b["gain_db"] >= 6:
                add(1, label, f"band {b['band']} boosts {b['gain_db']:+.1f} dB at {fmt_hz(b['hz'])}: large.")
            if b["type"] in ("peak", "vintage") and b["q"] >= 4 and b["gain_db"] >= 3:
                add(1, label, f"band {b['band']}: narrow boost (Q {b['q']:.1f}, {b['gain_db']:+.1f} dB at "
                              f"{fmt_hz(b['hz'])}) rings and invites feedback. Widen it (Q 1-2) or cut instead.")
        for i, a in enumerate(boosts):
            for b in boosts[i + 1:]:
                if octaves(a["hz"], b["hz"]) < 0.5 and a["type"] in ("peak", "vintage") and \
                        b["type"] in ("peak", "vintage"):
                    total = a["gain_db"] + b["gain_db"]
                    add(1, label, f"bands {a['band']} and {b['band']} both boost around {fmt_hz(a['hz'])} "
                                  f"(about {total:+.1f} dB together). One wider band does the same more cleanly.")
        total_boost = sum(b["gain_db"] for b in boosts)
        if len(boosts) >= 3 and total_boost >= 10:
            add(1, label, f"{len(boosts)} boosts adding up to {total_boost:+.1f} dB: the strip is mostly "
                          "compensating for something upstream (mic position, gain, another cut).")

        # Cuts that fight each other
        cuts = [b for b in active if b["gain_db"] < 0 and b["type"] in ("peak", "vintage")]
        for i, a in enumerate(cuts):
            for b in cuts[i + 1:]:
                if octaves(a["hz"], b["hz"]) < 0.3 and a["q"] >= 1 and b["q"] >= 1:
                    add(0, label, f"bands {a['band']} and {b['band']} both cut near {fmt_hz(a['hz'])}: "
                                  "merge into one.")

        # Monitors: feedback zone
        if is_bus:
            for b in boosts:
                if 1000 <= b["hz"] <= 4000 and b["type"] in ("peak", "vintage") and b["gain_db"] >= 2:
                    add(1, label, f"band {b['band']}: {b['gain_db']:+.1f} dB at {fmt_hz(b['hz'])} on a bus. "
                                  "If this feeds a stage monitor, that is the feedback zone: prefer cutting.")
        # Main
        if key == "main":
            if total_boost >= 6:
                add(1, label, f"main EQ adds {total_boost:+.1f} dB in total: leaves less headroom and is hard to "
                              "undo. A GEQ or cuts on the offending channels are safer.")
            shelf_low = [b for b in boosts if b["type"] == "low shelf" and b["gain_db"] >= 3]
            if shelf_low:
                add(1, label, "low shelf boost on the main ties up amplifier power below 100 Hz; check with music "
                              "you know before keeping it.")
    if flat_on:
        add(0, "Flat strips", "EQ on but every band flat (harmless): " + ", ".join(flat_on) + ".")
    findings.sort(key=lambda f: -f[0])
    return findings


def suggestions(model):
    """Starting points for channels whose name is recognised and whose EQ is empty."""
    out = []
    for key, strip in model.items():
        if not key.startswith("ch"):
            continue
        category, cut, hint = categorise(strip["name"])
        if category is None or category == "playback":
            continue
        has_eq = any(abs(b["gain_db"]) >= 0.5 for b in strip["bands"])
        lc_on = (strip["low_cut"] or {}).get("on", False)
        if not has_eq and strip["name"]:
            low = f"low cut ~{(cut[0] + cut[1]) // 2} Hz; " if cut and not lc_on else ""
            out.append(f"{strip['label']} «{strip['name']}» ({category}): {low}{hint}.")
    return out


def print_report(model, info=None):
    if info:
        print(f"Mixer: {info}")
    print(f"{len(model)} strips read.\n")
    print("== Overview ==")
    for strip in model.values():
        active = [b for b in strip["bands"] if b["type"] not in ("low cut", "high cut") and abs(b["gain_db"]) >= 0.5]
        lc = strip["low_cut"]
        lc_text = "-" if lc is None else (f"{fmt_hz(lc['hz'])}" if lc["on"] else "off")
        bands = "  ".join(f"{TAGS.get(b['type'], '?')}{fmt_hz(b['hz'])} {b['gain_db']:+.1f}dB" +
                          (f" Q{b['q']:.1f}" if b["type"] in ("peak", "vintage") else "") for b in active) or "flat"
        name = f"«{strip['name']}»" if strip["name"] else ""
        print(f"{strip['label']:<10}{name:<18}EQ {'on ' if strip['eq_on'] else 'OFF'}  LC {lc_text:<8}{bands}")

    findings = audit(model)
    print("\n== Findings ==")
    if not findings:
        print("Nothing stands out.")
    marks = {2: "!!", 1: "! ", 0: "· "}
    for level, strip, text in findings:
        print(f"{marks[level]} {strip}: {text}")

    ideas = suggestions(model)
    if ideas:
        print("\n== Starting points for channels with no EQ yet ==")
        for line in ideas:
            print("-", line)
    print("\nThese are rules of thumb from the numbers alone. The only real judge is the room: listen before "
          "and after, and keep a backup (Holly Mixer > Backups) before changing anything.")


# --- Self-test -------------------------------------------------------------------------------------

def norm_hz(hz):
    return math.log(hz / 20.0) / math.log(1000.0)


def selftest():
    def put(values, base, name, on, lc, bands):
        values[f"{base}/config/name"] = [name]
        values[f"{base}/eq/on"] = [1 if on else 0]
        if lc is not None:
            values[f"{base}/preamp/hpon"] = [1 if lc else 0]
            values[f"{base}/preamp/hpf"] = [math.log(100 / 20.0) / math.log(20.0)]
        for i, (t, hz, db, q) in enumerate(bands, 1):
            values[f"{base}/eq/{i}/type"] = [t]
            values[f"{base}/eq/{i}/f"] = [norm_hz(hz)]
            values[f"{base}/eq/{i}/g"] = [(db + 15) / 30]
            values[f"{base}/eq/{i}/q"] = [math.log(q / 10.0) / math.log(0.3 / 10.0)]

    values = {}
    flat = [(2, 400, 0, 1)] * 4
    put(values, "/ch/01", "Voz Pastor", True, False, [(2, 3000, 10, 6), (2, 3200, 4, 1), (2, 350, -3, 1), (4, 10000, 0, 1)])
    put(values, "/ch/02", "Bombo", False, True, [(2, 80, 5, 1), (2, 400, -6, 1.5), (2, 400, 0, 1), (2, 400, 0, 1)])
    put(values, "/ch/03", "CH 03", True, False, [(2, 1000, 3, 1)] + flat[:3])
    put(values, "/ch/04", "Guitarra", True, False, flat)
    put(values, "/bus/1", "Monitor", True, None, [(2, 2500, 5, 1)] + flat[:3] + flat[:2])
    put(values, "/lr", "LR", True, None, [(1, 60, 4, 1), (2, 250, 3, 1), (4, 12000, 2, 1)] + flat[:3])
    model = build_model(values)
    findings = audit(model)
    text = "\n".join(f"{s}: {t}" for _, s, t in findings)
    expect = ["very large", "narrow boost", "both boost around", "EQ is OFF", "low cut is off",
              "no name", "feedback zone", "main EQ adds", "low shelf boost on the main"]
    missing = [e for e in expect if e not in text]
    print_report(model)
    if missing:
        print("\nSELFTEST FAILED, rules not triggered:", missing)
        return 1
    print("\nSELFTEST OK")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("host", nargs="?", help="mixer IP address")
    parser.add_argument("--dump", help="audit a JSON written by xr18_dump.py instead of reading a mixer")
    parser.add_argument("--json", help="also write the EQ in real units to this file")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()

    if args.selftest:
        return selftest()
    info = None
    if args.dump:
        document = json.loads(pathlib.Path(args.dump).read_text())
        values = document.get("values", document)
        info = document.get("meta", {}).get("xinfo")
    elif args.host:
        values, info = read_live(args.host)
    else:
        parser.error("give the mixer's IP, or --dump FILE, or --selftest")

    model = build_model(values)
    if not model:
        print("No EQ values found.", file=sys.stderr)
        return 1
    print_report(model, info)
    if args.json:
        pathlib.Path(args.json).write_text(json.dumps({"mixer": info, "strips": model}, indent=1,
                                                      ensure_ascii=False))
        print(f"\nWrote {args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
