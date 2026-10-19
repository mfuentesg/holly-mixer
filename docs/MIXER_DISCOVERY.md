# Learning everything the mixer and the official app know

Goal: when the XR18 is reachable, collect the full parameter list, the value ranges and the exact addresses
each screen of X-AIR-Edit uses, then compare them with what Mixit implements (`XR18Params.swift`).

Everything below only reads. None of these steps changes the mixer.

## 1. Without the mixer: what REA gives from the official app

X-AIR-Edit 1.8.1 for macOS is a native universal Mach-O (arm64 + x86_64) with no resources beyond its icon and
one menu nib, so everything the app knows is inside the executable.

| Command | What you get | Status |
| --- | --- | --- |
| `rea inspect-macho <binary> --json` | architectures, load commands, build SDK, entry points | done (see the gap analysis) |
| `rea inspect-plist <app>/Contents/Info.plist` | bundle id `com.musictribe.X-AIR-Edit`, versions, URL schemes | quick |
| `strings -a -arch arm64 <binary>` | every OSC address template the app builds | done: `docs/xair-edit-osc-families.txt` |
| `rea analyze` / `function` / `decompile` (Hopper) | the functions that use those strings: value ranges, enumerations, which screen sends what | next step, needs Hopper (installed in `~/Applications`) |
| `rea observe-native-calls` (LLDB) | records calls into chosen functions while the app runs, for example the one that sends an OSC message | optional; may need Developer Tools access |

The official app also has a command line (from its release notes): `-i <ip> -x` connects and copies the mixer to
the app, `-s <index>` loads one of the 64 snapshots, `-f <scenefile>` loads a scene file. It can save scenes as
files, which are a full-state format worth comparing with the dump below (verify the format on a real file).

Suggested Hopper targets (search the string, then "references to"):
`/ch/%02d/gate`, `/ch/%02d/dyn`, `/ch/%02d/eq`, `/bus/%d/geq`, `/fx/%d`, `/routing/`, `/-snap/`, `/dca/`,
`/config/chlink`, `/-prefs/`. The conversion code next to each one shows the real units (dB, Hz, ms).

## 2. With the mixer: three captures

Run these from a computer on the mixer's network. Put them in one folder, for example `xair-captures/`.

### 2a. Full dump: what the mixer holds

```
python3 tools/xr18_dump.py dump 192.168.1.2 --snapshots
```

Writes `dump-<name>-<date>.json` with every answered address and value, plus the list of silent addresses (not
on this firmware). Run it again after switching the mixer off and on and compare:

```
diff <(python3 -m json.tool xair-captures/dump-A.json) <(python3 -m json.tool xair-captures/dump-B.json)
```

That diff shows exactly what the XR18 forgets at power-off, which is what Mixit's backup should protect.
Pass `--extra file.txt` to ask for more addresses (one per line) found in section 1.

### 2b. Live log: what the official app touches

```
python3 tools/xr18_dump.py listen 192.168.1.2
```

With X-AIR-Edit connected to the same mixer, type a note and press Enter, then move one control, for example
"gate threshold ch 1". Repeat for every screen (gate, dynamics, EQ, FX, routing, DCA, snapshots, preferences).
At the end you get `listen-<date>.jsonl` (every change with your notes) and `ranges-<date>.json` (minimum and
maximum seen for each address, which gives the value range once you sweep a knob end to end).

### 2c. Packet capture: what the official app sends

```
sudo tcpdump -i en0 -w xair.pcap udp port 10024
python3 tools/xr18_pcap_osc.py xair.pcap --writes
python3 tools/xr18_pcap_osc.py xair.pcap --timeline
```

This shows the app's own queries and changes, including the addresses it asks for when a page opens, which is the
list of parameters Mixit should request for the same page.

### 2d. Things in Mixit that follow the official app and still need hardware proof

- Mixer snapshots: `/-snap/NN/name` (read), `/-snap/load ,i N`, `/-snap/save ,i N`, `/-snap/index`. While the official
  app loads or saves a snapshot, run `xr18_dump.py listen` and compare the addresses it logs with these.
- DCA: `/dca/N/on`, `/dca/N/fader`, `/dca/N/config/name|color`, and `/ch/NN/grp/dca` as a bit mask (bit 0 = DCA 1).
  Move a DCA and add a channel to it in the official app and check the values in the log.

## 3. From captures to Mixit

1. Collect the addresses that exist (`dump`), the ones each screen uses (`listen`, pcap) and the ranges.
2. Add each one to `XR18Params.swift` with its `ParamRange` and enumerations, as the gate and dynamics already are.
3. Add the new addresses to `Mixer.fullStateAddresses` so the settings backup covers them.
4. Check the gap list in `docs/XAIR_EDIT_GAP_ANALYSIS.md` and tick items off.

## Self tests

The scripts can be checked without hardware:

```
python3 tools/xr18_dump.py --selftest
python3 tools/xr18_pcap_osc.py --selftest
```
