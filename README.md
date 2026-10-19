# Mixit

An iPad/iPhone remote for Behringer X AIR mixers (XR18 first), built as a modern replacement
for the X AIR app. See [docs/PLAN.md](docs/PLAN.md) for the full plan.

## What works now (v0.5)

Everything in the Mixit design canvas:

- **Mixer (iPad):** graphite console design, channels 1–16, Aux In, FX returns, buses, FX sends and
  Main LR with faders, mutes, solo, pan, EQ thumbnails, gate/compressor status, LED meters with peak hold;
  mute groups, undo with history, monitor mixes (sends on faders), "changed elsewhere" highlight
- **Channel detail:** tap a selected channel name (or a master's "EQ · Dyn"): Input (gain, +48V, polarity,
  low cut), Gate, interactive EQ, Dynamics, Sends, Config (name, colour)
- **Order of service:** scenes captured by the app, grouped Pre-service → Post, recall preview showing
  every change, live-signal warning, hold to recall, optional 2 s fade, recall safes, undo recall
- **Service Mode:** locked volunteer layout with big faders and min/max limits, PIN to exit, and an editor
- **iPhone:** portrait mixer with horizontal faders; musician "My mix" mode paired by QR code from the iPad
- **Connect:** finds mixers on the network, manual IP, recent mixers, network check, demo mixer
- **Settings backup:** Mixit saves every level, mute, name, EQ, gate and dynamics value on the device a few
  seconds after each change. If the XR18 is switched off and on and has lost them, a banner offers to
  restore them (phantom power is only restored if you ask). Manual saves, history of the last automatic
  backups, export and import between iPads
- **Service Mode footer:** NOW → NEXT with a hold-to-go button, and an optional "Call sound lead" button
- App icon from the design

No mixer nearby? Tap **Try the demo mixer** on the connect screen: a simulated XR18 with the
church's channel names, faders and mutes, and moving meters.

⚠️ Moving a fader or mute in Mixit really changes the mixer. Try it outside service times.

## Run it on an iPad with Swift Playgrounds

1. Install **Swift Playgrounds** from the App Store (free).
2. In Safari on the iPad, open
   <https://github.com/mfuentesg/mixit/archive/refs/heads/main.zip> and download it.
3. In the **Files** app, open Downloads and tap `mixit-main.zip` to unzip it.
4. Open the `mixit-main` folder and tap **Mixit** (the `Mixit.swiftpm` package).
   It opens in Swift Playgrounds. If it doesn't, long-press it → Share → Swift Playgrounds.
5. Tap **▶ Run** (or the app preview). Allow **Local Network** access when iOS asks.
6. Enter the mixer IP (`192.168.1.2` is pre-filled) and tap **Connect**.

To update later, repeat steps 2–4 (delete the old copy first).

The iPhone can't run Swift Playgrounds. It will get the app through TestFlight later.

## Network check without the app

`tools/xr18_probe.py` is a read-only check of the mixer connection. On iPad/iPhone, run it in the
free **a-Shell** app:

```
curl -L -o probe.py https://raw.githubusercontent.com/mfuentesg/mixit/main/tools/xr18_probe.py
python3 probe.py 192.168.1.2
```
