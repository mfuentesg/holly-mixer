#!/usr/bin/env python3
"""Suggests EQ changes from recordings made by xr18_eq_record.py, optionally with Claude. Never touches the mixer.

    python3 xr18_eq_suggest.py eq_sessions/ --roles eq_roles_holly.json            # local analysis only
    ANTHROPIC_API_KEY=sk-ant-... python3 xr18_eq_suggest.py eq_sessions/ --ai      # + Claude's suggestions
    python3 xr18_eq_suggest.py eq_sessions/ --ai --dry-run                         # show what would be sent

What it does:
  1. Local analysis of each recording (no network): third-octave balance, sustained narrow peaks (ringing /
     feedback candidates), rumble below the low cut, mud, harshness. Always runs.
  2. With --ai: sends a compact summary to Claude (strip name and role, current EQ, third-octave spectrum, level
     statistics) and asks for a complete proposed EQ per strip as JSON.
  3. Every proposal, from either source, goes through the same guard rails before it is shown or saved:
     band numbers and types the strip really has, frequency 20 Hz-20 kHz, gain limited to +/-6 dB per band,
     at most +9 dB of boost per strip, Q 0.3-10, low cut 20-250 Hz, no boost in the 1-4 kHz feedback zone on buses.
  4. The result is printed as "was -> proposed" and saved to eq_suggestions-<time>.json. Applying it is up to you.

Privacy with --ai: only strip names, roles, EQ numbers, spectrum and level statistics are sent. Never the IP, the
mixer's name or any backup. --dry-run prints exactly that payload and sends nothing. The key is read from
ANTHROPIC_API_KEY; never put it in a file in this repository.

Uses the official `anthropic` package when it is installed. Where it is not (for example Python on an iPad, which
cannot install it), it falls back to a plain HTTPS request so the script stays standard-library only.

Python 3.8+.
"""

import argparse
import copy
import datetime
import glob
import json
import math
import os
import pathlib
import statistics
import sys
import urllib.error
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import xr18_eq_audit as audit  # noqa: E402
import xr18_eq_record as record  # noqa: E402

DEFAULT_MODEL = "claude-opus-5-5"
MAX_GAIN = 6.0           # dB per band, first proposal
MAX_TOTAL_BOOST = 9.0    # dB per strip
MAX_LOW_CUT = 250.0      # Hz (the mixer goes to 400, but nothing sensible needs more)
ALLOWED_TYPES = ("low shelf", "peak", "high shelf")
THIRD_OCTAVES = [25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600,
                 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000]


# --- Loading ----------------------------------------------------------------------------------------

def load_sessions(paths):
    files = []
    for p in paths:
        path = pathlib.Path(p)
        files += sorted(glob.glob(str(path / "session-*.json"))) if path.is_dir() else [str(path)]
    sessions = []
    for f in files:
        data = json.loads(pathlib.Path(f).read_text())
        data["_file"] = f
        sessions.append(data)
    sessions.sort(key=lambda s: s["meta"]["taken"])
    return sessions


def merged_eq(sessions, eq_file=None):
    """Latest known EQ state per strip (later recordings win), or the file given with --eq."""
    if eq_file:
        document = json.loads(pathlib.Path(eq_file).read_text())
        return document.get("strips", document)
    model = {}
    for s in sessions:
        model.update(s.get("eq") or {})
    return model


# --- Spectrum analysis (local, no network) -----------------------------------------------------------

def third_octave(mean_db):
    """{centre Hz: dB} by power-averaging the bins inside each third-octave band."""
    freqs = [record.bin_frequency(i, len(mean_db)) for i in range(len(mean_db))]
    out = {}
    for centre in THIRD_OCTAVES:
        low, high = centre / 2 ** (1 / 6), centre * 2 ** (1 / 6)
        inside = [mean_db[i] for i, f in enumerate(freqs) if low <= f < high]
        if inside:
            out[centre] = round(record.to_db(sum(record.power(v) for v in inside) / len(inside)), 1)
    return out


def band_level(bands, low, high):
    values = [db for hz, db in bands.items() if low <= hz <= high]
    return record.to_db(sum(record.power(v) for v in values) / len(values)) if values else None


def analyse(session):
    """Findings from one recording: [{kind, hz, db, text}]. All thresholds are rules of thumb."""
    mean = session["rta"]["mean_db"]
    findings = []
    if session["frames"]["rta_active"] < 20:
        return [{"kind": "no-signal", "text": "very little signal was recorded: nothing reliable to say."}]
    n = len(mean)
    freqs = [record.bin_frequency(i, n) for i in range(n)]

    # Sustained narrow peaks: a bin well above the median of its neighbours (half an octave each side).
    for i in range(n):
        window = [mean[j] for j in range(max(0, i - 5), min(n, i + 6)) if j != i]
        excess = mean[i] - statistics.median(window)
        is_local_max = mean[i] >= mean[max(0, i - 1)] and mean[i] >= mean[min(n - 1, i + 1)]
        if excess >= 6 and is_local_max and 80 <= freqs[i] <= 12000:
            findings.append({"kind": "peak", "hz": round(freqs[i]), "db": round(excess, 1),
                             "text": f"sustained narrow peak near {audit.fmt_hz(freqs[i])} "
                                     f"(+{excess:.0f} dB over its surroundings): ringing or resonance."})

    bands = third_octave(mean)
    mid = band_level(bands, 500, 2000)
    if mid is not None:
        sub = band_level(bands, 25, 70)
        mud = band_level(bands, 200, 400)
        harsh = band_level(bands, 3000, 6300)
        if sub is not None and sub - mid > 8:
            findings.append({"kind": "rumble", "hz": 60, "db": round(sub - mid, 1),
                             "text": f"energy below 70 Hz is {sub - mid:+.0f} dB over the mids: rumble, "
                                     "a low cut (or a higher one) should help."})
        if mud is not None and mud - mid > 6:
            findings.append({"kind": "mud", "hz": 300, "db": round(mud - mid, 1),
                             "text": f"200-400 Hz is {mud - mid:+.0f} dB over the mids: boxy / muddy."})
        if harsh is not None and harsh - mid > 3:
            findings.append({"kind": "harsh", "hz": 4000, "db": round(harsh - mid, 1),
                             "text": f"3-6 kHz is {harsh - mid:+.0f} dB over the mids: harsh or sibilant."})
    return findings


# --- Guard rails ---------------------------------------------------------------------------------------

def sanitize(suggestion, key, strip):
    """Clamp a proposal to what the strip can do and to the safety limits. Returns (proposal, notes)."""
    notes = []
    count = len(strip["bands"])
    is_bus = key.startswith("bus")
    current_cut = strip.get("low_cut")

    low_cut = suggestion.get("low_cut_hz")
    if current_cut is None or not low_cut or low_cut <= 0:
        low_cut = None
    else:
        clamped = min(max(float(low_cut), 20.0), MAX_LOW_CUT)
        if clamped != low_cut:
            notes.append(f"low cut {low_cut:g} Hz limited to {clamped:g} Hz")
        low_cut = round(clamped, 1)

    bands, seen = [], set()
    for b in suggestion.get("bands", []):
        number = int(b.get("band", 0))
        if not 1 <= number <= count or number in seen:
            notes.append(f"band {number} does not exist on this strip: ignored")
            continue
        seen.add(number)
        kind = b.get("type") if b.get("type") in ALLOWED_TYPES else "peak"
        hz = min(max(float(b.get("hz", 1000)), 20.0), 20000.0)
        gain = float(b.get("gain_db", 0))
        q = min(max(float(b.get("q", 1.0)), 0.3), 10.0)
        if abs(gain) > MAX_GAIN:
            notes.append(f"band {number}: {gain:+.1f} dB limited to {math.copysign(MAX_GAIN, gain):+.0f} dB")
            gain = math.copysign(MAX_GAIN, gain)
        if is_bus and gain > 0 and kind != "high shelf" and 1000 <= hz <= 4000:
            notes.append(f"band {number}: boost in the feedback zone on a bus removed")
            gain = 0.0
        bands.append({"band": number, "type": kind, "hz": round(hz, 1), "gain_db": round(gain, 1),
                      "q": round(q, 2), "why": str(b.get("why", ""))[:300]})

    boosts = sum(b["gain_db"] for b in bands if b["gain_db"] > 0)
    if boosts > MAX_TOTAL_BOOST:
        scale = MAX_TOTAL_BOOST / boosts
        for b in bands:
            if b["gain_db"] > 0:
                b["gain_db"] = round(b["gain_db"] * scale, 1)
        notes.append(f"total boost {boosts:+.1f} dB scaled down to {MAX_TOTAL_BOOST:+.0f} dB")
    return {"strip": key, "low_cut_hz": low_cut, "bands": bands,
            "reasoning": str(suggestion.get("reasoning", ""))[:600]}, notes


def local_proposal(key, strip, findings):
    """A conservative proposal from the findings, using only bands that are flat today."""
    free = [b["band"] for b in strip["bands"] if abs(b["gain_db"]) < 0.5 and b["type"] not in ("low cut", "high cut")]
    bands, low_cut = [], None
    cut = strip.get("low_cut")
    for f in findings:
        if f["kind"] == "rumble" and cut is not None:
            low_cut = max(cut["hz"] * 1.5 if cut["on"] and cut["hz"] > 25 else 80, 80)
        elif f["kind"] in ("peak", "mud", "harsh") and free:
            hz = {"mud": 300, "harsh": 4000}.get(f["kind"], f.get("hz", 1000))
            gain, q = {"peak": (-3.0, 4.0), "mud": (-2.0, 1.0), "harsh": (-2.0, 1.2)}[f["kind"]]
            bands.append({"band": free.pop(0), "type": "peak", "hz": hz, "gain_db": gain, "q": q,
                          "why": f["text"]})
    return {"strip": key, "low_cut_hz": low_cut, "bands": bands,
            "reasoning": "Local rules from the recorded spectrum (conservative; only flat bands are used)."}


# --- Claude ---------------------------------------------------------------------------------------------

SCHEMA = {
    "type": "object", "additionalProperties": False, "required": ["summary", "strips"],
    "properties": {
        "summary": {"type": "string"},
        "strips": {"type": "array", "items": {
            "type": "object", "additionalProperties": False,
            "required": ["strip", "low_cut_hz", "bands", "reasoning"],
            "properties": {
                "strip": {"type": "string"},
                "low_cut_hz": {"type": "number"},
                "reasoning": {"type": "string"},
                "bands": {"type": "array", "items": {
                    "type": "object", "additionalProperties": False,
                    "required": ["band", "type", "hz", "gain_db", "q", "why"],
                    "properties": {
                        "band": {"type": "integer"},
                        "type": {"type": "string", "enum": list(ALLOWED_TYPES)},
                        "hz": {"type": "number"}, "gain_db": {"type": "number"}, "q": {"type": "number"},
                        "why": {"type": "string"}}}}}}}},
}

SYSTEM = """You are an assistant for a live-sound engineer at a small church using a Behringer XR18 mixer.
You propose EQ settings for the strips you are given. Rules:
- Be conservative. Prefer cuts to boosts; keep each band within +/-6 dB and the strip's total boost small.
- Return, for each strip, the COMPLETE proposed state: low_cut_hz (0 = leave the low cut off or absent) and the
  bands you want to set. Only use band numbers the strip has ("band_count"). Leave out bands that are fine as they are.
- Band types allowed: "low shelf", "peak", "high shelf". Frequencies 20-20000 Hz, Q 0.3-10 (Q only matters for peak).
- Use the evidence: the recorded third-octave spectrum (dB relative to the loudest band, power-averaged over the
  time the source was active), the local findings, the role and the current EQ. Without a spectrum, say your
  confidence is low and keep the changes small. Do not invent measurements.
- Voices need clarity (cut mud around 200-400 Hz, presence 2-5 kHz); monitors (buses) must avoid boosts around
  1-4 kHz because of feedback; the main EQ should stay nearly flat; "talkback" channels are not in the PA.
- Roles: voice, guitar, bass, keys, drums, kick, talkback, playback. Respect the people playing: do not call
  settings wrong that may be intentional; explain what you hear in the numbers.
- Write "why", "reasoning" and "summary" in Spanish, short and concrete (frequency, amount, reason)."""


def call_claude(user_text, model):
    """JSON object from Claude. Official SDK if installed, else a plain HTTPS request."""
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        sys.exit("Set ANTHROPIC_API_KEY to use --ai (never store it in the repository).")
    output_config = {"effort": "high", "format": {"type": "json_schema", "schema": SCHEMA}}
    messages = [{"role": "user", "content": user_text}]
    try:
        import anthropic  # type: ignore
    except ImportError:
        anthropic = None

    if anthropic is not None:
        client = anthropic.Anthropic(api_key=key)
        response = client.messages.create(model=model, max_tokens=16000, system=SYSTEM, messages=messages,
                                          output_config=output_config)
        stop, content = response.stop_reason, [b.model_dump() for b in response.content]
    else:
        body = json.dumps({"model": model, "max_tokens": 16000, "system": SYSTEM, "messages": messages,
                           "output_config": output_config}).encode()
        base = os.environ.get("ANTHROPIC_BASE_URL", "https://api.anthropic.com").rstrip("/")
        request = urllib.request.Request(
            base + "/v1/messages", data=body, method="POST",
            headers={"x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=180) as reply:
                payload = json.loads(reply.read())
        except urllib.error.HTTPError as error:
            sys.exit(f"Claude API error {error.code}: {error.read().decode(errors='replace')[:500]}")
        except urllib.error.URLError as error:
            sys.exit(f"Cannot reach the Claude API: {error.reason}")
        stop, content = payload.get("stop_reason"), payload.get("content", [])

    if stop == "refusal":
        sys.exit("Claude declined this request (stop_reason: refusal).")
    if stop == "max_tokens":
        sys.exit("The answer was cut off (max_tokens); try fewer strips per run.")
    text = "".join(b.get("text", "") for b in content if b.get("type") == "text")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        sys.exit("Claude's answer was not valid JSON:\n" + text[:500])


def build_payload(targets, eq, sessions_by_label, findings_by_label, roles):
    strips = []
    for key in targets:
        s = eq[key]
        session = sessions_by_label.get(key)
        entry = {
            "strip": key, "name": s.get("name", ""), "role": roles.get(key) or audit.role_of(key, s.get("name", ""))[0],
            "band_count": len(s["bands"]), "eq_on": s["eq_on"], "low_cut": s["low_cut"], "bands": s["bands"],
        }
        if session:
            bands = third_octave(session["rta"]["mean_db"])
            top = max(bands.values()) if bands else 0
            entry["recording"] = {
                "seconds": session["meta"]["seconds"], "note": session["meta"].get("note", ""),
                "active_frames": session["frames"]["rta_active"],
                "third_octave_db_rel_max": {str(hz): round(db - top, 1) for hz, db in bands.items()},
                "local_findings": [f["text"] for f in findings_by_label.get(key, [])],
                "level": session["levels"].get(key),
            }
        else:
            entry["recording"] = None
        strips.append(entry)
    return json.dumps({"strips": strips}, ensure_ascii=False, indent=1)


# --- Output ---------------------------------------------------------------------------------------------

def describe_band(b):
    q = f" Q{b['q']:.1f}" if b["type"] in ("peak", "vintage") else ""
    return f"{b['type']} {audit.fmt_hz(b['hz'])} {b['gain_db']:+.1f} dB{q}"


def show(proposals, eq, notes):
    for p in proposals:
        key = p["strip"]
        strip = eq[key]
        title = f"{strip['label']}" + (f" «{strip['name']}»" if strip["name"] else "")
        print(f"\n{title}   [{p.get('source', '')}]")
        cut = strip.get("low_cut")
        if p["low_cut_hz"]:
            was = "off" if not cut or not cut["on"] else audit.fmt_hz(cut["hz"])
            print(f"  low cut: {was} -> {audit.fmt_hz(p['low_cut_hz'])}")
        for b in p["bands"]:
            old = next((o for o in strip["bands"] if o["band"] == b["band"]), None)
            was = describe_band(old) if old else "?"
            print(f"  band {b['band']}: {describe_band(b)}   (now: {was})")
            if b.get("why"):
                print(f"      {b['why']}")
        if not p["low_cut_hz"] and not p["bands"]:
            print("  no change proposed.")
        if p.get("reasoning"):
            print(f"  → {p['reasoning']}")
        for n in notes.get(key, []):
            print(f"  (guard rail: {n})")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("sessions", nargs="+", help="session files or folders written by xr18_eq_record.py")
    parser.add_argument("--eq", help="eq.json from xr18_eq_audit.py --json (default: the EQ saved in the sessions)")
    parser.add_argument("--roles", help="JSON {\"ch09\": \"guitar\"}, as for xr18_eq_audit.py")
    parser.add_argument("--strips", help="comma list of strip keys to work on (default: the recorded strips)")
    parser.add_argument("--ai", action="store_true", help="also ask Claude (needs ANTHROPIC_API_KEY)")
    parser.add_argument("--dry-run", action="store_true", help="with --ai: print the payload, send nothing")
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--out", default=".", help="folder for eq_suggestions-<time>.json")
    args = parser.parse_args()

    sessions = load_sessions(args.sessions)
    if not sessions:
        sys.exit("No session files found.")
    roles = json.loads(pathlib.Path(args.roles).read_text()) if args.roles else {}
    audit.ROLES.update(roles)
    eq = merged_eq(sessions, args.eq)
    if not eq:
        sys.exit("No EQ data: record without --no-eq, or pass --eq eq.json.")

    by_label = {}
    for s in sessions:  # newest recording of each label
        by_label[s["meta"]["label"]] = s
    findings = {label: analyse(s) for label, s in by_label.items()}

    print("== Recordings ==")
    for label, s in by_label.items():
        m = s["meta"]
        print(f"{label:<8} {m['taken']}  {m['seconds']:.0f} s  signal frames {s['frames']['rta_active']}"
              + (f"  «{m['note']}»" if m.get("note") else ""))
        for f in findings[label]:
            print(f"    - {f['text']}")
    if not any(s["meta"].get("rta_axis", {}).get("verified") for s in sessions):
        print("\nNote: the RTA frequency axis (log, 20 Hz-20 kHz) is assumed, not yet verified on hardware.")

    wanted = args.strips.split(",") if args.strips else [k for k in by_label if k in eq]
    targets = [k for k in wanted if k in eq]
    if not targets:
        sys.exit("No recorded strip matches a strip in the EQ data. Use --label ch01 / bus1 / main when recording.")

    proposals, notes = [], {}
    for key in targets:
        raw = local_proposal(key, eq[key], findings.get(key, []))
        clean, n = sanitize(raw, key, eq[key])
        clean["source"] = "local rules"
        proposals.append(clean)
        notes[key] = n

    if args.ai:
        payload = build_payload(targets, eq, by_label, findings, roles)
        if args.dry_run:
            print("\n== Would be sent to Claude (model " + args.model + ") ==\n" + SYSTEM + "\n\n" + payload)
        else:
            print(f"\nAsking {args.model} about {len(targets)} strip(s)...", file=sys.stderr)
            answer = call_claude(payload, args.model)
            print("\n== Claude: summary ==\n" + answer.get("summary", ""))
            ai_proposals = []
            for item in answer.get("strips", []):
                key = item.get("strip")
                if key not in eq:
                    continue
                clean, n = sanitize(item, key, eq[key])
                clean["source"] = "Claude"
                ai_proposals.append(clean)
                notes.setdefault(key, []).extend(n)
            proposals = ai_proposals or proposals

    print("\n== Proposals (guard rails applied) ==")
    show(proposals, eq, notes)

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    path = pathlib.Path(args.out) / f"eq_suggestions-{stamp}.json"
    path.write_text(json.dumps({"made": stamp, "proposals": proposals, "guard_rail_notes": notes},
                               indent=1, ensure_ascii=False))
    print(f"\nSaved {path}. Nothing was changed on the mixer. Keep a backup before applying anything, "
          "and listen before and after.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
