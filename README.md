# Mixit

An iPad/iPhone remote for Behringer X AIR mixers (XR18 first), built as a modern replacement
for the X AIR app. See [docs/PLAN.md](docs/PLAN.md) for the full plan.

## What works now (v0.2)

- Connects to the mixer by IP (remembers the last one) and reconnects after Wi-Fi drop-outs
- Channels 1–16 and Main LR: names, colours, faders, mutes, live meters
- Aux In, FX returns 1–4, Bus 1–6 and FX send 1–4 masters
- Monitor mixes: pick a bus or FX send at the top and the faders become that mix's sends
- Changes made on the mixer or in other apps show up live
- Faders follow your finger without jumping; double-tap a fader for 0 dB

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
