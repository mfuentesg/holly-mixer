# Design brief: Mixit, an iPad & iPhone app to control a Behringer XR18 digital mixer

You are a senior product designer for pro-audio and live-production tools. Design a complete,
high-fidelity UI for **Mixit**, a native iPadOS/iOS app that remotely controls a **Behringer XR18**
digital mixer (and later the X32 family) over Wi-Fi. It replaces Behringer's official "X AIR" app,
which is outdated and unmaintained. It must have **full feature parity** with X AIR and be much
easier, safer and more beautiful to use.

## 1. Context and users

- **Where:** a church sound booth. The room is dim during services, the iPad sits on a mic-stand
  clamp or a table about 40–70 cm away, and the operator often stands. There are quick glances
  between the stage and the screen.
- **Primary user:** the church's sound lead. Knows audio and wants speed and depth.
- **Secondary users:**
  - **Rotating volunteers** with little training. They need a simple, safe mode where they can't
    break anything.
  - **Musicians** adjusting their own in-ear/wedge monitor mix from their iPhone on stage.
- **Moments that matter:**
  - Muting/unmuting the pastor's mic instantly.
  - Riding the worship leader's vocal.
  - Fixing a musician's monitor mix mid-song.
  - Recovering when "someone touched something".
  - Recovering when Wi-Fi drops.
- **Language:** UI in English, but channel names are user content in Spanish, e.g. "Pulpito",
  "Batería", "Martín". Support accents and names up to 12 characters.

## 2. Mixer facts the design must cover (XR18)

| Item | Detail |
|---|---|
| Inputs | 16 mic/line channels, Aux In (stereo, ch 17/18), 4 stereo FX returns, USB returns |
| Mixes | 6 aux buses (monitor mixes; can be linked into stereo pairs), 4 FX sends, Main LR |
| Groups | 4 DCAs, 4 mute groups |
| Per channel | Name (12 chars), colour (8 colours: off/grey, red, green, yellow, blue, magenta, cyan, white; plus inverted variants), icon, preamp gain, +48V phantom, polarity, low-cut, gate, 4-band parametric EQ, compressor, insert FX, sends to 6 buses + 4 FX (pre/post), pan, mute, solo, fader |
| Buses / Main | 6-band EQ, compressor, insert, fader, mute |
| FX | 4 slots (reverbs, delays, chorus/flanger, graphic EQ, limiter, etc.) with type-specific editors |
| Other | Routing (outputs, USB), meters, RTA, 64 snapshots (scenes), preset libraries, several clients connected at once |
| Fader | 0 dB at 75% of travel; range −∞ to +10 dB; scale marks 10, 5, 0, −5, −10, −20, −30, −40, −50, −∞ |
| Meters | about 20 updates/s, −60…0 dBFS; green below −18, amber −18 to −6, red above −6 |

**Real sample data (use it in mockups):**

| Ch | Name | Colour | Fader |
|---|---|---|---|
| 1 | Pulpito | yellow | +7.8 dB |
| 2 | Mic Oscar | yellow | +6.9 |
| 3 | Guitarra Acus | cyan | +0.7 |
| 4 | Bajo | cyan | −3.0 |
| 5 | Mic Martin | yellow | +7.3 |
| 6 | Mic Cata | yellow | +6.0 |
| 7 | Voz Off | red | −∞ |
| 8 | Guit Marcelo | cyan | −8.5 |
| 9 | Martín | cyan | −1.7 |
| 10 | Batería | cyan | +0.7 |
| 11 | Maxi | cyan | −6.0 |
| 12–16 | unnamed | grey | — |

Main LR is at −1.5 dB. Mixer name "XR18-C3-D7-F9", firmware 1.16, IP 192.168.1.2.
Invent sensible bus names: "Monitor Pulpito", "IEM Batería", "IEM Bajo", "Wedge Coro",
"Stream", "Lobby".

## 3. Design principles

1. **Never surprise the operator.** No accidental fader jumps, no hidden state. Destructive
   actions (scene recall, phantom power, unlink, network changes) need a confirm sheet or a
   press-and-hold, and anything can be undone.
2. **One touch to the common things.** Mute pastor, raise worship lead, open a monitor mix:
   each is reachable from any screen.
3. **Progressive disclosure.** Simple surface, full depth one tap away.
4. **Readable in the dark from arm's length.** High contrast, large hit targets (≥ 44 pt;
   faders and mutes larger), no thin grey-on-grey text for anything important.
5. **State is always visible.** Connection, current scene, which mix the faders control,
   muted/soloed channels, demo mode.
6. **Native, not skeuomorphic kitsch.** It should feel like a modern Apple pro app
   (Logic Pro for iPad, Final Cut) crossed with a premium digital console. Precise, calm, tactile.

## 4. Visual direction

- **Theme:** dark "graphite console" by default, plus a light theme for daytime rehearsals.
  Near-black blue-grey background (#0B0C0F → #121318), cards #1C1E21 with 1 px white-7% borders,
  12 pt corner radius.
- **Accent:** one warm accent (orange #FF8A1F) for app chrome and selection only. Channel colours
  come from the mixer and identify channels; don't use them decoratively.
- **Channel palette (refine it):** grey #737373, red #F55757, green #4DD175, yellow #FACC42,
  blue #528FFA, magenta #DB6BE0, cyan #4DC7EB, white #EBEBEB. Must stay distinguishable for
  colour-blind users; pair colour with text/number.
- **Status colours:** meters green #40D973, amber #FFC233, red #FF4D47. Mute red #ED3D3D with a
  soft glow when active. Solo amber/yellow. Demo mode purple.
- **Type:** SF Pro / SF Pro Rounded for labels, SF Mono or tabular digits for every number
  (dB, Hz, ms). Channel names in semibold rounded, 13–15 pt.
- **Icons:** SF Symbols only.
- **Motion:** only where it carries meaning: meters, gain-reduction, fader cap lift on touch,
  a short cross-fade when switching mixes, a scene-recall progress sweep. Respect Reduce Motion.
- **Haptics:** a detent tick at 0 dB, a firm tap on mute, success/warning on scene recall.

## 5. Signature components (design these in detail, all states)

1. **Channel strip** (about 78 pt wide on iPad), top to bottom:
   - colour bar
   - channel number
   - name
   - mini EQ curve thumbnail
   - gate/comp gain-reduction pills
   - pan arc
   - fader with dB scale and the channel-coloured level line
   - segmented LED meter beside the fader
   - dB readout pill
   - SOLO and MUTE buttons

   States: default, selected, muted (name and fill dimmed), soloed, being dragged, "changed
   elsewhere" flash (another client moved it), sends-mode tint, disabled/locked.
2. **Fader:**
   - Cap with grip lines and a centre line in the channel colour.
   - It moves relative to the finger (no jumping); only the cap is grabbable so horizontal swipes
     scroll the strip row.
   - Double-tap goes to 0 dB; long-press types a value.
   - Two-finger drag gives fine control.
   - Show the drag affordance and the fine-mode state.
3. **Meter:** segmented LED style with peak hold and a clip indicator. Mono and stereo variants.
4. **Mix selector:** chips for Main LR, Bus 1–6 and FX 1–4 with the bus colour dot and name.
   Selecting a bus switches every fader to "sends on faders" mode:
   - The strips are tinted in the bus colour.
   - A banner reads "Faders are sends to IEM Batería" with a Back to Main control.
   - The bus master replaces Main LR in the pinned right-hand strip.

   This mode must be impossible to confuse with the main mix.
5. **Bank bar:** 1–8, 9–16, Aux · FX, Buses · FX Sends, ★ Custom.
6. **Top bar:**
   - app mark
   - mixer name, model and firmware
   - connection pill (Connected / Reconnecting… / Demo)
   - current scene with ◀ ▶
   - mute group buttons MG1–4
   - undo
   - main LR meter
   - disconnect

## 6. Screens to design

### iPad, landscape first (also 11" and 13", portrait, and Split View half width)

1. **Connect / onboarding:**
   - Auto-discovered mixers list, manual IP field, recent mixers, "Try the demo mixer".
   - Local Network permission explainer; "Check my network" diagnostics showing latency,
     packet loss and guest-network warnings.
2. **Mixer (home):** 12–16 strips visible, scrollable row, pinned Main LR strip on the right,
   mix selector, bank bar. Show it with the sample data above.
3. **Mixer in sends-on-faders mode:** Bus 2 "IEM Batería" selected.
4. **Channel detail:** a right-side inspector or full-screen sheet for "Pulpito", with tabs:
   - **Input:** source, gain, +48V with a confirm, polarity, low-cut with frequency.
   - **Gate:** with a transfer-curve graph.
   - **EQ:** a large interactive curve. Drag band dots for frequency/gain, pinch for Q, band type
     picker, RTA drawn behind the curve.
   - **Dynamics:** threshold, ratio, knee, attack, release, makeup, gain-reduction meter,
     transfer curve.
   - **Sends:** 6 buses + 4 FX as horizontal faders with pre/post.
   - **Config:** name, colour, icon, link.
5. **Bus / Main processing:** 6-band EQ and compressor, same language as the channel.
6. **FX rack:**
   - 4 slots with type picker cards.
   - Editors for a hall reverb (decay graph), a stereo delay (tap tempo, time in ms and note
     values) and a 31-band graphic EQ.
7. **Routing:** outputs 1–6, main, phones/solo source, USB sends/returns as a clear patch grid.
8. **Meters & RTA:** a full meter bridge of all inputs, buses and outputs; a fullscreen RTA with
   peak hold.
9. **Scenes / order of service:**
   - Snapshots arranged as a service timeline: Pre-service → Worship → Sermon → Response → Post.
   - Next/previous controls.
   - A **recall preview** showing what will change (a diff list) before confirming.
   - Save, rename, recall-safe options.
10. **Undo / history:** a timeline of changes ("10:42 · Mic Oscar fader +3.1 dB") with revert.
11. **Service Mode (volunteer):**
    - An admin builds a locked layout with only big faders for "Pastor", "Worship Lead", "Band",
      "Playback" and "Main", with min/max limits; advanced pages are hidden; PIN to exit.
    - Design both the editor and the locked result.
12. **Pre-service checklist:** phantom where needed, expected mutes, wireless mics showing
    signal, main fader set; one-tap "fix all".
13. **Feedback assistant / ring-out wizard:** detects a ringing frequency on the RTA and proposes
    a one-tap narrow cut. A step-by-step guided flow.
14. **Settings:** network (AP/LAN/static), mixer info, preferences (fader size, meter style,
    theme), accounts/permissions, backups (iCloud show files).

### iPhone

15. **Mixer, portrait:** a vertical list of **horizontal** faders (8–10 visible), mute and solo
    on the left, swipe a row for channel detail. Landscape: 8 vertical faders.
16. **Musician monitor mode:**
    - Onboarding by scanning a QR code shown on the iPad.
    - Opens straight into "My mix" (e.g. "IEM Bajo") with a pinned "Me" row (their own mic) on
      top and big faders for the rest.
    - Locked to that bus; no access to anything else.

### System states (show on the relevant screens)

- **Reconnecting:** the UI stays usable but read-only and dimmed, with an orange banner and a
  retry countdown.
- **Permission denied:** guidance to Settings › Privacy › Local Network.
- **Mixer not found:** troubleshooting tips.
- **Demo mode:** a purple pill and an "Exit demo" control.
- **Scene recall in progress** and **firmware mismatch warning**.
- **Two clients editing the same control:** a "changed elsewhere" flash.
- Empty and loading states (initial sync progress bar, under 2 s).

## 7. Accessibility

- VoiceOver: faders are adjustable elements ("Pulpito fader, plus 7.8 dB").
- Dynamic Type for all non-strip text.
- WCAG AA contrast minimum (AAA for mute/solo/state).
- Don't rely on colour alone.
- Reduce Motion and Reduce Transparency variants.
- Hit targets ≥ 44 pt.

## 8. Constraints

- Implemented in **SwiftUI (iOS/iPadOS 17+)**. Prefer native controls and materials; custom
  controls only for faders, meters, EQ/dynamics graphs and the mix selector.
- Meters render at 20–60 fps, so keep them simple shapes (no heavy blur on animated layers).
- No Behringer/X AIR trademarks or logos; describe compatibility only.
- The app name is **Mixit**. Design an app icon (fader + soundwave idea, dark with orange accent)
  and a small logomark for the top bar.

## 9. Deliverables

1. A design-system page:
   - colour tokens (dark and light), type scale, spacing (4 pt grid), radii, shadows, elevation
   - component library with every state: strip, fader, meter, knob, toggle, mix chip, bank button,
     mute/solo, pill, banner, sheet, EQ node
2. High-fidelity frames for every screen above:
   - iPad 13" landscape (1366×1024 pt) as the primary size
   - iPad 11" landscape
   - iPhone 15/16 portrait and landscape
3. Key interaction specs (annotated or as short prototypes):
   - fader drag and fine mode
   - double-tap to unity
   - mix switch transition
   - scene recall preview → confirm
   - undo
   - Service Mode PIN exit
   - QR pairing for monitor mode
4. Redlines/specs that an engineer can implement directly in SwiftUI (sizes in pt, colours as
   hex, font styles), plus exported SF Symbol names.

Make it feel calm, confident and premium: the kind of tool a volunteer trusts on a Sunday
morning and a professional engineer enjoys using.
