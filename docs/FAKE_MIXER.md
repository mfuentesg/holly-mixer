# Fake mixer (`tools/fake_xair.py`)

A local fake Behringer X AIR XR18 that speaks OSC over UDP port 10024. Use it to test Holly Mixer's connection
handling, reconnects, protocol edge cases and the "mixer lost its settings" flow without hardware. Python 3
standard library only.

## Start it

```
python3 tools/fake_xair.py                                   # 0.0.0.0:10024, scenario "normal"
python3 tools/fake_xair.py --scenario flaky-wifi
python3 tools/fake_xair.py --latency-ms 80 --jitter-ms 40 --loss 10
python3 tools/fake_xair.py --port 10025 --ip 192.168.1.50 -v
```

Options: `--host`, `--port`, `--latency-ms N` (delay of every reply), `--jitter-ms N` (extra random 0..N ms),
`--loss PERCENT` (applied to incoming and outgoing packets), `--scenario NAME`, `--ip` (address reported by
`/xinfo`, default is this Mac's LAN IP), `--snap-prefix /snap|/-snap` (default `/-snap`, like a real XR18 on firmware 1.16), `--xremote-timeout SECONDS` (default 10),
`-v` (log every received message). Flags given explicitly override the scenario's own values.

The app always talks to port 10024, so keep the default port when testing the app. The Python tools can also be
pointed at it: `python3 tools/xr18_probe.py 127.0.0.1`, `python3 tools/xr18_dump.py dump 127.0.0.1`.

## Point the app at it

- iOS simulator: it shares the Mac's network, so type `127.0.0.1` on the app's connect screen.
- Physical iPhone/iPad: type the Mac's LAN IP (printed in the startup line, "reports IP ..."), with both on the same
  Wi-Fi and the Mac firewall allowing Python to accept incoming connections.
- The in-app Demo mode is separate and does not use this server.

## What it implements

- OSC 1.0 parse and encode: int32, float32, string, blob; bundles are unpacked; malformed packets are ignored.
- `/xinfo` (`ip, name, model, firmware`), `/info`, `/status` (`active, ip, name`). Model XR18, firmware 1.16.
- Get (address with no value) and set (address with a value). A set is stored and pushed to every `/xremote`
  subscriber except the sender (the real mixer does not echo back to the sender, as the app's demo also assumes).
  Types are kept: a float sent to an int parameter is rounded, an int sent to a float parameter is converted.
- `/xremote` subscription: lasts 10 s, silent clients expire, at most 8 clients (a 9th is ignored). `/renew`
  renews the sender's `/xremote` and meter subscriptions (with a string argument, only that meter).
- `/meters ,s "/meters/N"` subscriptions (also expire after 10 s), streamed about every 50 ms as one blob
  (int32 LE count, then int16 LE in 1/256 dB). Meter 1 has 40 values, meter 6 (gain reduction, negative dB) has 39,
  and the others have the sizes from `docs/XAIR_PROTOCOL_NOTES.md` (0: 8, 2: 36, 3: 56, 4: 100, 5: 44, 7: 16, 8: 4,
  9: 4). Levels move like the in-app demo; gate and compressor reduction on meter 6 follows each channel's
  `gate/on` and `dyn/on`.
- Parameter state seeded from the in-app demo (`DemoTransport.swift`, `DemoSeeds.swift`): channels 1-16 (Pulpito,
  Mic Oscar, ...), aux and FX returns, buses 1-6, FX sends, main LR: name, colour, fader, mute (`mix/on`), pan,
  sends (`mix/NN/level`), gate, dynamics, EQ bands, low cut, `headamp/NN/gain` and `phantom`, invert, solo
  (`/-stat/solosw/NN`), DCA groups (`/dca/N/...`, `grp/dca` bit masks), mute groups `/config/mute/1-4`.
- Snapshots (64 slots, the spelling chosen by `--snap-prefix`): `/snap/name`, `/snap/index`, `/snap/load N`,
  `/snap/save N`, `/snap/delete N`, `/snap/NN/name` (31 characters), `/snap/NN/scope` (stored and returned).
  Slots 1-5 start with the demo names and hold the demo scene. Loading a slot restores its values and pushes the
  changes to subscribers. Loading an empty slot does nothing.
- Any other address (for example parts of the tree that are not seeded) is a generic store: a set remembers the last
  value, a get replies only if something was stored or seeded. Unknown gets are silent, as on the real mixer.
- Several clients at once.

## Scenarios (`--scenario`, or `scenario NAME` in the console)

| Name | Behaviour |
| --- | --- |
| `normal` | well-behaved mixer |
| `flaky-wifi` | 15% loss, 30 ms latency, up to 80 ms jitter |
| `slow` | 400 ms latency plus up to 50 ms jitter |
| `no-xremote` | ignores `/xremote` and `/renew`, so nothing is ever pushed; gets, sets and meters still work |
| `powercycle-after-60s` | 60 s after start the mixer power-cycles: 3 s silent, then factory settings |
| `wrong-firmware` | reports firmware 1.08 and, as an approximation of old firmware, ignores `/snap/...` and `/meters/6` |
| `unreachable` | binds the port but never answers (type `resume` to start answering) |

## Runtime console

Type these on stdin while it runs (`help` lists them):

| Command | Effect |
| --- | --- |
| `status` | scenario, faults, subscribers, meter subscriptions, snapshot count, packet counters |
| `drop on\|off` | cable pulled: ignore and send nothing (changes sent meanwhile are lost) |
| `freeze` / `resume` | keep receiving and applying changes but send nothing / reply again (`resume` also clears `drop`) |
| `latency MS`, `jitter MS`, `loss PERCENT` | network faults, applied to replies, pushes and meters |
| `powercycle [SECONDS]` | switch off (silent for SECONDS, default 0), then return with factory settings: names empty, faders at 0 dB, nothing muted, flat EQ, gain 0 dB, phantom off. All subscriptions are forgotten; snapshots survive |
| `elsewhere ADDRESS VALUE` | change a value as if another device did and push it to every subscriber, e.g. `elsewhere ch/03/mix/fader 0.5` |
| `get ADDRESS` | print a stored value |
| `kick` | forget all `/xremote` and meter subscribers |
| `changeip` | report a new random IP in `/xinfo` |
| `quiet` / `loud` / `normal` | meters at silence / hot (about +14 dB, clipping at 0) / demo levels, to test live-signal warnings |
| `snapshot N [NAME]` | save the current state to slot N |
| `scenario NAME` | apply a scenario |
| `quit` | exit |

## What it does NOT simulate

- Audio, routing, real DSP, or any behaviour of the real mixer beyond the OSC messages above.
- Value ranges and validation: values are stored as sent (only the int/float coercion above); floats are not clamped.
- Mute groups and DCAs do not act on other parameters: setting `/config/mute/N` or a DCA fader changes only that value.
- Snapshot scope: the scope string is stored but loads always restore every stored value. Snapshots are in memory
  only and are lost when the script exits.
- Stereo links, `/node`, `/-action`, FX parameters, routing and graphic EQ values are not seeded (they work as the
  generic store, so a get is silent until something is set).
- Wi-Fi and Ethernet details: loss, latency and jitter are applied in software on this side, to replies and pushes
  and on incoming packets, not as real network behaviour. The `changeip` command only changes the IP text in
  `/xinfo`; the server stays on its socket.
- The real mixer's behaviour with firmware older than 1.11 is approximated by `wrong-firmware`, not verified.
- Anything unverified in `docs/XAIR_PROTOCOL_NOTES.md` (for example the sign and scale of meter 6) is mirrored from
  the app's own assumptions, not from hardware.

## Tests

```
python3 -m unittest tools.test_fake_xair -v
```

The tests start the server on a random port inside the test process and cover info replies, get/set, `/xremote`
echo and expiry, the 8-client limit, meters, loss, latency, freeze/drop, power cycle, snapshots and the scenarios.
