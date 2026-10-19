# X AIR remote control protocol: notes

Source: "X AIR Mixer Series Remote Control Protocol" (firmware 1.11 or higher), the manufacturer's PDF. These are
notes in our own words, not a copy. The PDF says that a separate file, **Parameters.txt**, holds every OSC path and
parameter range; it is not part of the PDF and is the most useful missing piece.

## Transport

- OSC over UDP, port 10024. Replies go back to the sender's address and port.
- `/info` or `/xinfo` returns version, name, model and firmware; `/status` returns "active" or "standby".
- `/xremote` makes the mixer push every parameter change to up to **eight** clients; it lasts 10 seconds and must be
  renewed (Mixit renews every 8 s). So up to eight apps can be connected at once.
- Get: send an address with no value; the mixer echoes the value. Set: send the address with a value.
- Types: floats are always 0.0 to 1.0, integers are signed 32 bit, booleans are integers, strings end with a null,
  everything is big-endian and padded to 4 bytes.

## Meters

Subscribe with `/meters ,s "/meters/N"` (an optional integer picks a channel for `/meters/0`). The reply is one blob:
a 32-bit count followed by signed 16-bit values in 1/256 dB.

| ID | Content |
| --- | --- |
| 0 | one channel: pre-fader L/R, gate and compressor gain reduction, post-fader L/R, gate key, comp key |
| 1 | 16 mono, 5 stereo pairs (aux + 4 FX returns), 6 buses, 4 FX sends (all pre), 2 main (post), 2 monitor: 40 values (Mixit uses this) |
| 2 | inputs: 16 mic, 2 aux, 18 USB: 36 values |
| 3 | FX meters: 4 x (2 in, 10 returns, 2 out): 56 values |
| 4 | **RTA, 100 bins** |
| 5 | outputs: 6 aux, main, 16 P16, 18 USB, headphones: 44 values |
| 6 | **dynamics**: 16 gate, 16 channel dynamics, 6 bus dynamics, main dynamics: 39 values (Mixit uses this for the gain reduction meter) |
| 7 | automix gains: 16 values |
| 8 | DCA: 4 values |
| 9 | recorder: 2 record, 2 play |

## Snapshots

- `/snap/name` and `/snap/index` fill a temporary buffer that the next `save` or `load` uses.
- `/snap/load N`, `/snap/save N`, `/snap/delete N` (N = 1 to 64) act on a slot.
- `/snap/NN/name` (31 characters at most) and `/snap/NN/scope` change a slot immediately; no save is needed.
- `scope` is 59 characters of `+` (recalled) or `-`, in this order: channels 1 to 16, aux 17 to 18, FX returns 1 to 4,
  bus masters 1 to 6, FX send masters 1 to 4, main LR, DCA 1 to 4, FX 1 to 4, then source, input, config, EQ, dynamics,
  bus sends 1 to 6, FX sends 1 to 4, fader and pan, mute, routing, console configuration.

## What this changed in Mixit

- Snapshots use `/snap/...` (Mixit also tries `/-snap/...` and uses whichever the mixer answers to); saving sends the
  name through `/snap/name` and then `/snap/save N`; delete is supported.
- The gate and compressor gain-reduction meter reads `/meters/6`. The sign and scale of those values are an assumption
  (negative dB for reduction): verify on hardware.
- Ideas it opens: snapshot **recall scope** editing (the 59-character string, which is the XR18's own "recall safe"),
  an RTA view from `/meters/4`, and DCA meters.
