# Soundcraft Ui24R support

Holly Mixer was built for the Behringer XR18 and speaks X AIR OSC everywhere. A Soundcraft Ui24R (and Ui16 / Ui12,
same protocol) is supported by **translating**: `Ui24Transport` talks to the mixer and turns its messages into the X AIR
addresses the rest of the app already uses, so the mixer screens, undo, backups and musician mode work unchanged.

**Status: written from the protocol below, not yet tried on a real Ui24R.** Test outside service times first.

## How the app finds and connects to it

- `AutoTransport` (the app's only real transport) opens both an X AIR UDP connection and a Ui WebSocket to the same
  address and keeps whichever answers first. Saved addresses, typed addresses and musician pairings all work for
  either mixer; nothing stores the mixer type.
- `MixerDiscovery.scan` also looks for Ui mixers: every address on the local /24 with TCP port 80 open, plus the
  recent addresses and `10.10.1.1` (the mixer on its own "Soundcraft Ui24…" hotspot), gets a WebSocket probe
  (`Ui24Probe`). The model and firmware come from the `model` and `firmware` keys of the state dump.
- `Mixer.isSoundcraft` (model "Ui24R", "Ui16" or "Ui12") hides what isn't mapped: the Gate, EQ and Dynamics tabs, the
  polarity, low-cut, colour and DCA cards, and the snapshots row.

## Protocol

From the open-source [soundcraft-ui-connection](https://github.com/fmalcher/soundcraft-ui) library (v7.1).

- WebSocket to `ws://<ip>/` (port 80). Text frames start with `3:::` and may hold several lines separated by `\n`.
- On connect the mixer sends its whole state as `SETD^key^number` and `SETS^key^text` lines. There is no "get".
- The client sends the same lines (each frame prefixed with `3:::`) and `3:::ALIVE` every second.
- Meters: `VU2^<base64>`. Byte 0–6 are counts (inputs, players, subgroups, FX, auxes, masters, line inputs), then from
  byte 8 a block per strip: inputs/players/line 6 bytes (pre, post, post-fader…), subgroups/FX 7 (post L/R,
  post-fader L/R…), auxes/masters 5 (post, post-fader…). A byte × 0.004167508 is 0…1 over −80…0 dB.
- Fader values are 0…1 on the Ui's own taper (0 = −∞, 1 = +10 dB, ~0.765 = 0 dB); `Ui24Protocol.faderGain` is the
  library's fit, checked against it to 0.1 dB.

## Address map (`Ui24Map`)

| X AIR address (app) | Ui key | Conversion |
|---|---|---|
| `/ch/NN/mix/fader`, `/on`, `/pan`, `/config/name` | `i.(N-1).mix`, `.mute`, `.pan`, `.name` | taper; mute inverted |
| `/ch/NN/mix/01…06/level` | `i.(N-1).aux.0…5.value` | taper |
| `/ch/NN/mix/07…10/level` | `i.(N-1).fx.0…3.value` | taper |
| `/ch/NN/grp/mute` | `i.(N-1).mgmask` (low 4 bits; others kept) | *unverified key* |
| `/-stat/solosw/NN` | `i.(N-1).solo` | |
| `/headamp/NN/gain`, `/phantom` | `hw.(N-1).gain`, `.phantom` (Ui16/12: `i.(N-1)…`) | −6…57 dB (Ui16/12: −40…50) ↔ −12…60 dB |
| `/rtn/aux/…` | `l.0` (line in) | as channels |
| `/rtn/1…4/…` | `f.0…3` | no pan |
| `/bus/1…6/…` | `a.0…5` | no pan |
| `/lr/mix/fader`, `/pan` | `m.mix`, `m.pan` | `/lr/mix/on` is always 1 |
| `/dca/1…4/fader`, `/on`, `/config/name` | `v.0…3.mix`, `.mute`, `.name` | |
| `/config/mute/1…4` | `mgmask` bits 0–3 | |
| `/fxsend/1…4/mix/fader`, `/on` | none | fixed at 0 dB / on |

Stereo-linked inputs (`i.N.stereoIndex` 0 or 1) get the same fader, mute, solo and send change on the other half, as
the Ui web app does. Channels 17–24, auxes 7–10, VCAs 5–6, players and subgroups are not shown. VCA membership,
colours, EQ, dynamics, effects and the Ui's show/snapshot system are not mapped yet.

## Testing without the mixer

`sudo python3 tools/fake_ui24.py` serves a fake Ui24R on port 80 (state dump, SETD/SETS relay to other clients,
moving `VU2` meters). In the simulator, connect to `127.0.0.1`. See [FAKE_MIXER.md](FAKE_MIXER.md).

## To verify on hardware

1. The app finds the mixer on its hotspot and on a router network; the connect row reads "Soundcraft Ui24R".
2. Faders, mutes, sends and VCAs move the same controls in the Ui web app, and back.
3. `i.N.mgmask` is really the per-channel mute group membership.
4. Meters: inputs use the post-processing byte, auxes/FX/master the post-fader byte; check they look right.
5. Whether the mixer echoes a change back to the client that sent it (harmless either way).
