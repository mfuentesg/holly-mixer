# Holly Mixer

An iPad/iPhone remote for Behringer X AIR mixers (XR18 first), built as a modern replacement
for the X AIR app. See [docs/PLAN.md](docs/PLAN.md) for the full plan.

## What works now (v0.5)

Everything in the Holly Mixer design canvas:

- **Mixer (iPad):** graphite console design, channels 1–16, Aux In, FX returns, buses, FX sends and
  Main LR with faders, mutes, solo, pan, EQ thumbnails, gate/compressor status, LED meters with peak hold;
  mute groups, undo with history, monitor mixes (sends on faders), "changed elsewhere" highlight
- **Channel detail:** tap a selected channel name (or a master's "EQ · Dyn"): Input (gain, +48V, polarity,
  low cut), Gate, interactive EQ, Dynamics, Sends, Config (name, colour)
- **Order of service:** scenes captured by the app, grouped Pre-service → Post, recall preview showing
  every change, live-signal warning, hold to recall, optional 2 s fade, recall safes, undo recall
- **Service Mode:** (hidden for now, see below)
- **iPhone:** portrait mixer with horizontal faders; musician "My mix" mode paired by QR code from the iPad
- **Connect:** finds mixers on the network, manual IP, recent mixers, network check, demo mixer
- **Settings backup:** Holly Mixer saves every level, mute, name, EQ, gate and dynamics value on the device a few
  seconds after each change. If the XR18 is switched off and on and has lost them, a banner offers to
  restore them (phantom power is only restored if you ask). Manual saves, history of the last automatic
  backups, export and import between iPads
- **Safer power cycles:** a safety copy is saved before every scene recall, Service Mode and snapshot load;
  optional automatic restore with a visible 10 s countdown (it waits while the sound system is live)
- **DCA groups:** the four DCAs as faders (iPad bank "DCA", iPhone bank "DCA") and DCA membership per channel
  (channel page, Config tab)
- **Mixer snapshots:** list, load and save the mixer's own 64 snapshot slots (commands to be verified on a real mixer)
- **Service Mode** (hidden in this version, `FeatureFlags.serviceMode`): the locked volunteer layout, its editor and the PIN to leave it. Its NOW → NEXT footer and "Call sound lead" button come with it
- **Service Mode footer (hidden with Service Mode):** NOW → NEXT with a hold-to-go button, and an optional "Call sound lead" button
- **English and Spanish:** the language follows the device (Spanish if it is Spanish, otherwise English) and can be
  changed with the globe button on the Connect screen or in the `…` menu. Texts live in
  `HollyMixer.swiftpm/es.lproj/Localizable.strings` (English text = key)
- App icon from the design

No mixer nearby? Tap **Try the demo mixer** on the connect screen: a simulated XR18 with the
church's channel names, faders and mutes, and moving meters.

⚠️ Moving a fader or mute in Holly Mixer really changes the mixer. Try it outside service times.

## Run it on an iPad with Swift Playgrounds

1. Install **Swift Playgrounds** from the App Store (free).
2. In Safari on the iPad, open
   <https://github.com/mfuentesg/holly-mixer/archive/refs/heads/main.zip> and download it.
3. In the **Files** app, open Downloads and tap `holly-mixer-main.zip` to unzip it.
4. Open the `holly-mixer-main` folder and tap **HollyMixer** (the `HollyMixer.swiftpm` package).
   It opens in Swift Playgrounds. If it doesn't, long-press it → Share → Swift Playgrounds.
5. Tap **▶ Run** (or the app preview). Allow **Local Network** access when iOS asks.
6. Enter the mixer IP (`192.168.1.2` is pre-filled) and tap **Connect**.

To update later, repeat steps 2–4 (delete the old copy first).

The iPhone can't run Swift Playgrounds. It will get the app through TestFlight later.

## Network check without the app

`tools/xr18_probe.py` is a read-only check of the mixer connection. On iPad/iPhone, run it in the
free **a-Shell** app:

```
curl -L -o probe.py https://raw.githubusercontent.com/mfuentesg/holly-mixer/main/tools/xr18_probe.py
python3 probe.py 192.168.1.2
```
