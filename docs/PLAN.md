# Mixit — iPad & iPhone remote for Behringer X AIR (XR18 first) and X32

> Working name: **Mixit**. Goal: a modern, maintained replacement for Behringer's X AIR app
> that has full feature parity with it, and is much easier to use, especially for church
> volunteers running a Sunday service.

---

## 1. Scope & hardware facts

| | **XR18 / MR18 (primary target)** | XR16 / XR12 | X32 / M32 family (phase 4) |
|---|---|---|---|
| Protocol | OSC over UDP, port **10024** | same | OSC over UDP, port **10023** |
| Inputs | 16 mic + stereo Aux (17/18) + USB | 12 / 8 + aux | 32 + 8 aux |
| Mix buses | 6 aux (linkable to stereo pairs) | 4 | 16 |
| FX | 4 stereo slots, 4 FX sends/returns | 4 | 8 |
| DCA / mute groups | 4 / 4 | 4 / 4 | 8 / 6 |
| Snapshots | 64 | 64 | 100 scenes |
| Extras | 18×18 USB interface, built-in Wi-Fi AP | — | Matrix, mono/center bus, AES50, USB recorder, talkback |

> Note: there is no "XR32". I'm assuming you mean the **X32** (X32 Rack, Compact, Producer).
> It speaks a close sibling of the same OSC protocol, so it fits in as a later phase if the
> core is built around a per-console **parameter schema** rather than hard-coded addresses.

The protocol facts the design relies on (all to be confirmed on your XR18 in Phase 0):

- **Discovery:** send `/xinfo` to UDP 10024 → reply `,ssss` = IP, name, model, firmware.
- **Keep-alive / push:** send `/xremote` at least every 10 s, and the mixer pushes every
  change made by other clients (the X AIR app, other iPads, the front panel of an X32).
- **Read:** send an address with no arguments → mixer replies with the current value.
  `/node ,s "ch/01/mix"` returns a whole subtree as one text line, which makes the initial sync fast.
- **Write:** `/ch/01/mix/fader ,f 0.75`, `/ch/01/mix/on ,i 0`, `/headamp/01/phantom ,i 1`, …
- **Meters:** subscribe with `/meters ,s "/meters/N"` (renew < 10 s). Replies are binary blobs
  of int16 values in 1/256 dB, about 20 Hz.
- **Value mapping:** faders are a float 0…1 mapped to dB in 4 linear segments
  (0.5–1 → −10…+10 dB, 0.25–0.5 → −30…−10, 0.0625–0.25 → −60…−30, below that → −∞…−60).
  Frequencies are log-mapped 20 Hz–20 kHz, gain/Q/time have their own curves.
  All of this lives in one tested `ValueMapping` module.

---

## 2. Product principles

1. **Never surprise the person mixing.** No accidental fader jumps, no hidden state.
   Every destructive action (snapshot recall, phantom power, unlinking) can be undone or needs confirmation.
2. **Fast at the common things.** Mute the pastor's mic, bring up the worship leader,
   tweak a monitor mix: each is **one touch from any screen**.
3. **Deep when needed.** Every XAir parameter is reachable, but kept behind progressive disclosure.
4. **Built for a dark stage.** Dark UI by default, high-contrast meters, large hit targets,
   readable from 1 m away on an iPad on a mic stand.
5. **Resilient.** Wi-Fi drops are common in churches. The app keeps the UI, reconnects by
   itself, resyncs, and clearly shows when it's offline.

---

## 3. Feature parity checklist (everything X AIR has)

**Connection & setup**
- Auto-discovery, manual IP, recent mixers, demo/offline mode
- Network config: AP / LAN DHCP / static, Wi-Fi channel and security
- Firmware/model info, mixer name, preferences (fader taper, meter style, lock)

**Mixer (main view)**
- Channel faders 1–16, Aux in, FX returns 1–4, USB return, buses 1–6, FX sends 1–4, Main LR, DCAs 1–4
- Mute, solo, pan/balance, meters (pre/post), names, colors, icons
- "Sends on faders" for any bus or FX send (the key monitor-mix workflow)
- Mute groups 1–4, DCA assignment, channel/bus link (stereo pairs)

**Channel strip, per input**
- Config: source (analog/USB/aux), name, color, icon, link, delay
- Preamp: gain, trim, +48 V phantom, polarity, low-cut (HPF) on/frequency
- Gate: mode (Exp 2/3/4, Gate, Ducker), threshold, range, attack, hold, release, key source, key filter
- EQ: 4 bands, type (LCut, LShv, PEQ, VEQ, HShv, HCut), freq/gain/Q, with an interactive curve
- Dynamics: comp/exp, threshold, ratio, knee, attack, hold, release, makeup, mix, peak/RMS,
  lin/log envelope, auto-time, key source and filter
- Insert: FX slot assignment
- Sends: bus 1–6 levels, pre/post tap, FX sends 1–4, main LR assign

**Buses / Main LR**
- 6-band EQ, dynamics, insert, link, outputs, tap points

**FX rack**
- 4 slots: type picker (reverbs, delays, modulation, GEQ/TruEQ, limiter, combinator, …)
- Per-type editors with parameter curves (GEQ faders, reverb decay graph)
- Insert vs. send/return usage

**Routing**
- Analog outputs 1–6 + main, phones/solo source
- USB send sources 1–18 and USB returns, input source patching
- Routing presets

**Meters & RTA**
- Meter bridge for all inputs, buses and outputs
- RTA (on the EQ view and fullscreen), peak hold

**Scenes & libraries**
- 64 snapshots: save, recall, rename, safes/recall scope
- Channel, FX and routing preset libraries
- Import/export of `.scn` / `.snap` files

**Multi-user**
- Lock to a single bus ("personal monitor"), lock the whole UI, several clients at once

---

## 4. Beyond X AIR (the "incredible" part)

These are why someone would switch, and they matter most in a church with rotating volunteers.

| Feature | What it does |
|---|---|
| **Undo / history** | Every change is recorded. Shake or ⌘Z to undo; history timeline with "revert to 10:42". The best fix for "a volunteer touched something". |
| **Service Mode (simple mode)** | An admin builds a locked layout with only the controls a volunteer needs (e.g. "Pastor", "Worship Lead", "Band", "Playback", "Main"), with big faders, min/max limits and hidden advanced pages. PIN to exit. |
| **Musician monitor mode (iPhone)** | Musicians scan a QR code → their phone opens straight into *their* bus with their channel names and "me" (their own mic) pinned on top. They can't touch anything else. |
| **Scene timeline** | Snapshots arranged as the order of service (Pre-service → Worship → Sermon → Response → Post). Next/previous buttons, with a **preview of what changes before recall** (diff). |
| **Feedback assistant** | Uses the RTA to detect a ringing frequency and suggests (one tap) a narrow cut on the bus/main EQ or GEQ. Includes a guided "ring out the monitors" wizard. |
| **Gain-staging helper** | During soundcheck, shows each channel's peak meter against a target zone and suggests a preamp gain. |
| **Pre-service checklist** | Phantom on where needed, mutes as expected, wireless mics present (signal on the meter), main fader set. One-tap "fix all". |
| **Show-file backup** | Automatic snapshot of the full mixer state to iCloud each time you connect; restore to any mixer. Diff two shows. |
| **Fine-control gestures** | Drag with two fingers for 1/10 resolution, double-tap → 0 dB, long-press → type a value, haptic tick at 0 dB and at −∞. |
| **Customizable layouts** | User fader banks (any channels, any order), favorites, a "pin" strip that's always visible. |
| **Spill** | Tap a DCA or a linked group → only its members are shown on the faders. |
| **Accessibility** | VoiceOver ("Pastor mic, fader −5 dB, adjustable"), Dynamic Type, reduced motion, colour-blind safe meter palette. |
| **Hardware controllers (later)** | Bluetooth MIDI (e.g. a small fader box) and keyboard shortcuts on iPad. |

---

## 5. UX design

### 5.1 Navigation model

```
┌ Top bar ─────────────────────────────────────────────────────────────────────┐
│ ● XR18 "Church"  │  Scene: Worship ◀ ▶  │  MG1 MG2 MG3 MG4  │  Undo  │  LR meter │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│                Main area (Mixer / Channel / FX / Routing / Meters)           │
│                                                                              │
├──────────────────────────────────────────────────────────────────────────────┤
│ Layer bar:  Inputs 1-8 │ 9-16 │ Aux/FX │ Buses │ DCA │ ★ Custom  │ Mix: [LR ▾] │
└──────────────────────────────────────────────────────────────────────────────┘
```

- **Mix selector** (bottom right) is the central idea: choosing `Bus 3 – Drummer IEM` turns every
  fader into the send level to that bus, tinted in the bus colour, so it's never confused with
  the main mix. This is "sends on faders" made obvious.
- The **selected channel** is always highlighted. On iPad a right-side **inspector** shows its
  strip (Gain · Gate · EQ · Dyn · Sends · Config) without leaving the mixer.

### 5.2 iPad (landscape, the primary form factor)

- 8 or 16 faders visible (setting), each about 70 pt wide on 11" models.
- Channel strip, from top to bottom: name/colour tab → mini EQ curve thumbnail (tap → EQ) →
  mini gate/comp gain-reduction indicators → pan → mute/solo → **fader with meter alongside** → dB readout.
- Inspector panel (collapsible, about 380 pt): tabs with live graphs. EQ shows a full-width
  interactive curve; drag a band dot to change freq/gain, pinch to change Q, RTA drawn behind it.
- Split View / Stage Manager: the app works at half width (falls back to the iPhone layout).

### 5.3 iPhone

- **Portrait:** vertical list of *horizontal* faders (8–10 visible at once, thumb-friendly),
  mute and solo on the left, swipe left on a row → channel detail.
- **Landscape:** 8 vertical faders, like a small console.
- **Monitor mode** is portrait-first: "My mix" header, pinned "Me" row, big faders.

### 5.4 Interaction rules

- Faders move **relative to the touch** (grab anywhere on the track, no jump to the finger).
- A vertical drag on a fader never scrolls; horizontal swipes on the layer bar change banks.
- While a finger is on a control, incoming network updates for that parameter are ignored
  (prevents rubber-banding when two people touch the same thing).
- Destructive toggles (phantom, snapshot recall, unlink, network settings) use a confirm sheet
  or a press-and-hold.
- Colours: the channel colour from the mixer tints the name tab and fader cap; meters
  use green → yellow → red with a clear clip-hold indicator.

### 5.5 Visual style

- Dark "graphite" theme, one accent colour, SF Pro / SF Mono for numbers, subtle material blur
  on panels. A light theme exists for daytime rehearsals.
- Motion only where it carries information (meters, gain-reduction, scene-change crossfade preview).

---

## 6. Technical architecture

**Stack:** Swift 6, SwiftUI, Observation (`@Observable`), Swift Concurrency, `Network.framework`.
iOS/iPadOS 17+. No third-party dependencies in the core (OSC is easy to implement and test).
The same code runs on macOS via Catalyst / "Designed for iPad" for free.

```
Mixit (app target)
├── MixerKit (Swift package, no UI)
│   ├── OSC/            encoder/decoder, bundles, blobs: pure, 100% unit-tested
│   ├── Transport/      UDPTransport (NWConnection), keep-alive, reconnect, rate limiting
│   ├── Discovery/      /xinfo probing, manual IP, recent devices
│   ├── Schema/         per-model parameter tables (XR18, XR16, XR12, X32): address, type, range, mapping
│   ├── State/          MixerState: tree of observable parameters, sync engine, echo suppression
│   ├── Meters/         meter subscriptions, blob parsing, ring buffers (kept outside SwiftUI state)
│   ├── Scenes/         snapshot I/O, .scn import/export, diff
│   └── Simulator/      in-process fake mixer for tests, previews and demo mode
├── MixitUI (Swift package)
│   ├── Controls/       Fader, Knob, MeterView (Canvas/Metal), EQCurveView, GainReductionView
│   ├── Screens/        Mixer, ChannelStrip, FXRack, Routing, Meters, Scenes, Setup
│   └── Modes/          ServiceMode, MonitorMode, layout editor
└── Tests/              unit, snapshot (UI), integration against the simulator
```

Key decisions:

1. **Schema-driven, not hard-coded.** Every parameter is described once:
   `Param(path: "/ch/{n}/eq/{b}/f", type: .float, mapping: .log(20, 20000), unit: .hz)`.
   The UI binds to params by key. Supporting X32 = adding a schema plus a few model-specific screens.
2. **One source of truth.** `MixerState` mirrors the mixer. UI writes become an *optimistic local update
   plus an OSC send*. Mixer pushes (via `/xremote`) update the same state, so other clients stay in sync.
3. **Fine-grained observation.** Each parameter is its own observable object, so a fader move
   re-renders one view, not the whole mixer.
4. **Outgoing rate control.** Coalesce sends per parameter to about 50 Hz (only the latest value is
   sent) to avoid flooding the XR18's weak Wi-Fi AP.
5. **Meters bypass SwiftUI diffing.** Meter data goes into a lock-free buffer drawn by a
   `TimelineView` + `Canvas` (or Metal if needed) at display refresh rate.
6. **Initial sync** uses `/node` subtree requests, chunked and paced. Target: full state in under 2 s
   on LAN, a progress bar in the meantime.
7. **Undo** is a command log at the `MixerState` level (param, old, new, timestamp, source).
   Gestures are grouped into one entry (a whole fader drag = one undo step).
8. **Persistence:** SwiftData for local layouts, service-mode configs and show backups;
   CloudKit sync for show files.

**iOS networking gotchas to handle early**
- `NSLocalNetworkUsageDescription` is required, and the system prompt must be explained in onboarding.
- **UDP broadcast** for discovery needs Apple's `com.apple.developer.networking.multicast`
  entitlement (request it from Apple). Fallbacks: unicast `/xinfo` sweep of the /24 subnet, plus manual IP.
- The XR18's built-in AP is 2.4 GHz and weak. Recommend (in the app's help) putting the
  mixer on a dedicated router via Ethernet, and show live latency/packet-loss in the connection indicator.
- Handle background/foreground: stop meters when backgrounded, resubscribe and resync on return.

---

## 7. Roadmap

### Phase 0: Protocol spike (1–2 weeks)
- OSC codec plus tests; connect to *your* XR18; discovery; read/write a fader; meter blob parsing.
- Record a capture of the X AIR app talking to the mixer (Wireshark) to confirm addresses,
  `/node` format and meter layouts for your firmware.
- Build the Simulator from that capture so most development doesn't need the mixer.

### Phase 1: "Sunday-ready" MVP (4–6 weeks)
- Connection screen, auto-reconnect, demo mode
- Mixer view (iPad + iPhone): faders, mute, solo, pan, meters, names/colours, layers
- Sends-on-faders for buses 1–6 and FX 1–4
- Channel strip: gain, phantom, polarity, HPF, 4-band EQ with curve, compressor
- Main LR and bus faders, mute groups, DCAs
- Snapshot list: recall (with confirm), save, rename
- Undo
- **Exit criteria:** run a real Sunday service from the iPad without touching X AIR.

### Phase 2: Full X AIR parity (6–8 weeks)
- Gate, full dynamics, key sources, insert
- Bus and Main processing (6-band EQ, dyn)
- FX rack with editors for every effect type
- Routing (outputs, USB, input sources), presets/libraries
- RTA, meter bridge, recall scope/safes, `.scn` import/export
- Network setup, lock modes, mixer preferences

### Phase 3: Church superpowers (4–6 weeks)
- Service Mode with layout editor and PIN
- Musician Monitor mode with QR onboarding
- Scene timeline with change preview (diff)
- Pre-service checklist, gain-staging helper, feedback assistant / ring-out wizard
- iCloud show backups

### Phase 4: X32 / M32 and polish
- X32 schema (port 10023, 32 ch, 16 buses, matrix, 8 DCA, talkback, USB recorder)
- MR18/MR12 branding variants, Bluetooth MIDI controllers, Mac app
- App Store release, TestFlight for other churches

---

## 8. Quality & testing

- **Unit:** OSC encode/decode, every value mapping (round-trip dB ↔ float), schema coverage
  (every XR18 address the X AIR app uses is present).
- **Integration:** UI flows against the Simulator, including packet loss and latency injection.
- **Hardware-in-the-loop checklist** before each release: run on your XR18 with 2–3 devices
  connected at once, alongside the X AIR app, to verify sync both ways.
- **Performance budgets:** fader touch → OSC packet < 16 ms; 60 fps (120 on ProMotion) with all meters
  running; < 5% CPU idle on an iPad 9th gen.
- **Field test:** two Sunday services in "shadow mode" (X AIR as backup) before switching.

---

## 9. Risks

| Risk | Mitigation |
|---|---|
| Undocumented or firmware-specific OSC details | Wireshark captures, community docs (Patrick-Gilles Maillot's X32/XAir OSC docs), simulator built from real traffic |
| Multicast entitlement delayed by Apple | Unicast subnet sweep + manual IP work without it |
| Weak XR18 Wi-Fi → laggy UX | Rate limiting, optimistic UI, latency indicator, router guidance |
| Two clients fighting over one control | Touch-lock echo suppression, "edited elsewhere" flash indicator |
| Scope creep (X32 too early) | Schema design keeps X32 cheap later. Ship XR18 first |
| Trademark | Don't use "Behringer"/"X AIR" in the app name; describe compatibility only |

Competitive note: **Mixing Station** (third-party, paid) already supports the XR18 well and is the
quality bar. Mixit should win on simplicity, church-specific workflows (Service Mode, monitor QR,
scene timeline, feedback assistant), undo, and a native iPad-first feel.

---

## 10. Our church setup

The XR18 is connected by **Ethernet to the church router**, and the iPad/iPhone joins that router's Wi-Fi.
This is the recommended setup, and it shapes the first version:

| | |
|---|---|
| Model | XR18 |
| Firmware | 1.16 |
| IP | 192.168.1.2 (router LAN 192.168.1.0/24) |
| Name | `XR18-C3-D7-F9` (factory default, derived from the MAC address) |

**Probe results (iPad on church Wi-Fi, run in a-Shell):**

- `/xinfo`, `/status`, single-parameter reads and the `/meters/1` subscription (40 values) all work.
- Latency: median 3.0 ms, max 3.2 ms, 0/20 lost. The network has plenty of headroom.
- The very first send failed with `EHOSTUNREACH` (errno 65) until iOS's Local Network permission
  was granted. The app must treat that error as "waiting for permission" and retry, not as "mixer offline".
- `/node ch/01/mix` got no reply on the `/node` address (the X32 replies on `node`, without a slash;
  now under test). If firmware 1.16 doesn't support it, the initial sync falls back to pipelined
  per-parameter reads. At 3 ms RTT and ~30 requests in flight, a full sync still fits the 2 s budget.

To check the connection from a laptop on the church Wi-Fi, run the read-only probe
`python3 tools/xr18_probe.py 192.168.1.2`. It never changes mixer settings, so it's safe during a service.

- **Connection:** the app talks to the mixer's LAN IP on UDP 10024. The XR18's built-in AP is not used.
- **Stable IP:** give the XR18 a **DHCP reservation** (or a static IP outside the DHCP pool) on the
  router, so the app's "recent mixer" entry never goes stale. The app still re-discovers by `/xinfo`
  if the saved IP stops answering.
- **Discovery on this network:** a unicast `/xinfo` sweep of the router's /24 subnet finds the mixer
  without needing Apple's multicast entitlement, so Phase 0 can start before Apple approves it.
- **Router settings to check:** "AP/client isolation" and "guest network" must be off for the
  Wi-Fi the tablets use, or they can't reach the mixer. Use the 5 GHz band for the iPads.
- **Onboarding** gets a "Check my network" step: same subnet, mixer reachable, round-trip latency,
  packet loss. It also warns if the device is on a guest SSID.

## 11. Next steps

1. Run `tools/xr18_probe.py` at church and check that `/node` and `/meters` behave as expected on firmware 1.16.
2. Phase 0 spike: create the Xcode project + `MixerKit` package, OSC codec, connect to the mixer.
3. Clickable mockups of the iPad mixer view, channel inspector and Service Mode to validate the UX
   with the volunteers who'll actually use it.
