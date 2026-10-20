# Holly Mixer

An iPad/iPhone remote for Behringer X AIR mixers (XR18 first), built as a modern replacement
for the X AIR app. See [docs/PLAN.md](docs/PLAN.md) for the full plan.

📖 **User manual (Spanish, with screenshots):** [docs/MANUAL_ES.md](docs/MANUAL_ES.md)

## What works now (v0.6)

Everything in the Holly Mixer design canvas:

- **Mixer (iPad):** graphite console design, channels 1–16, Aux In, FX returns, buses, FX sends and
  Main LR with faders, mutes, solo, pan, EQ thumbnails, gate/compressor status, LED meters with peak hold;
  mute groups, undo with history, monitor mixes (sends on faders), "changed elsewhere" highlight
- **Channel detail:** tap a selected channel name (or a master's "EQ · Dyn"): Input (gain, +48V, polarity,
  low cut), Gate, interactive EQ, Dynamics, Sends, Config (name, colour)
- **Simple view (for the pastor):** the sound lead chooses which input channels someone sees; he gets one big MUTE button per channel (optional volume slider) and nothing else. It locks the device it is started on (each device is set up once), and leaving it can require a PIN
- **iPhone:** portrait mixer with horizontal faders; in landscape the iPad mixer in a compact layout (extras hidden,
  SOLO and MUTE side by side) so every control fits; musician "My mix" mode set up on the phone with the mixer address, monitor and channel
- **Safety on a live system:** a channel silenced by a mute group or a muted DCA shows "G1" / "DCA2" on its MUTE
  button; mute groups can be named and show how many channels they hold; in a monitor mix the strip button takes the
  channel out of that mix instead of muting the room; a double-tap resets a fader only from its cap, and never from
  far below; undo shows what it reverted; disconnect asks first; a musician's phone can require a PIN to leave
- **Mix selector:** Main LR and the six monitor buses; the effects (FX 1–4) are hidden by default and can be shown
  with a Settings switch (each channel's Sends tab always has its FX sends)
- **Simple navigation:** no strip banks. The iPad shows every strip in one scrolling row and the iPhone one scrolling
  list (channels, aux/FX, buses, DCA); the four mute groups sit in the bottom bar; a visible **Settings** button
  opens one page with mute groups (and which channels are in each), backups, snapshots, pairing and language
- **iPhone:** Main LR pinned under the list, a banner and a back button in monitor mixes, the solo pill, the channel
  page with a pinned fader/mute/solo bar, and a "I'm a musician" card on the Connect screen
- **Faders:** only a clear vertical drag on the cap moves a fader, so swiping sideways across the strips scrolls
  without touching levels; stereo strips keep the cap clear of the meters
- **Connect:** finds mixers on the network, manual IP, recent mixers, network check, demo mixer. No address is
  assumed on a first run, and if the saved address stops answering (the router gave the mixer a new IP) the app
  looks for it and follows it when it is clearly the same mixer
- **Settings backup:** Holly Mixer saves every level, mute, name, EQ, gate and dynamics value on the device a few
  seconds after each change. If the XR18 is switched off and on and has lost them, a banner offers to
  restore them (phantom power is only restored if you ask). Manual saves, history of the last automatic
  backups, export and import between iPads
- **Safer power cycles:** a safety copy is saved before every snapshot load;
  optional automatic restore with a visible 10 s countdown (it waits while the sound system is live)
- **DCA groups:** the four DCAs as faders (last strips on the iPad, last section on the iPhone) and DCA membership per channel
  (channel page, Config tab)
- **Mixer snapshots:** list, load and save the mixer's own 64 snapshot slots (commands to be verified on a real mixer)
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
6. Tap the mixer that appears under *Found on this network*, or type its IP and tap **Connect**.

To update later, repeat steps 2–4 (delete the old copy first).

The iPhone can't run Swift Playgrounds. It will get the app through TestFlight later. To install on a device
from a Mac, open `HollyMixer.swiftpm` in Xcode, pick your team and run (bundle id `com.mfuentesg.hollymixer`).

## Developing

- **Demo mixer:** in-app simulated XR18 (connect screen → *Try the demo mixer*).
- **Fake mixer server:** see [docs/FAKE_MIXER.md](docs/FAKE_MIXER.md) (`tools/fake_xair.py`), a local fake X AIR
  OSC server with fault injection (packet loss, latency, power-cycle reset, "changed elsewhere") for testing
  connection and restore flows without hardware.
- **Manual screenshots:** debug builds accept `SIMCTL_CHILD_HM_SHOT=<screen>` (see `ScreenshotMode.swift`) to open the
  demo mixer directly on a screen when launched with `xcrun simctl launch`.
- Protocol and discovery notes: [docs/XAIR_PROTOCOL_NOTES.md](docs/XAIR_PROTOCOL_NOTES.md),
  [docs/MIXER_DISCOVERY.md](docs/MIXER_DISCOVERY.md).

## Network check without the app

`tools/xr18_probe.py` is a read-only check of the mixer connection. On iPad/iPhone, run it in the
free **a-Shell** app:

```
curl -L -o probe.py https://raw.githubusercontent.com/mfuentesg/holly-mixer/main/tools/xr18_probe.py
python3 probe.py 192.168.1.2
```
