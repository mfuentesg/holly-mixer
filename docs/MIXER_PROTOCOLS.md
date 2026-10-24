# Other mixers: protocols and feasibility

Research for adding more mixers to Holly Mixer after the XR18 and the Soundcraft Ui24R (October 2026). Ports and
protocol details come from manufacturer documents where they exist, otherwise from community projects; everything
marked *unverified* needs checking on hardware.

## Short answer

| Priority | Mixer family | Protocol | Docs | Effort | Why |
|---|---|---|---|---|---|
| 1 | **Behringer X32 / Midas M32** (incl. X32 Rack, Compact, Producer) | OSC over UDP 10023 | Community (Maillot), very complete | **Small–medium** | Same OSC dialect as the XR18; very common in churches |
| 1 | **Behringer XR12 / XR16, Midas MR12 / MR18** | Same as XR18 (UDP 10024) | Same as XR18 | **Small** | Already connects; only channel/bus counts differ |
| 1 | **Soundcraft Ui12 / Ui16** | Same as Ui24R | Same as Ui24R | **Small** | Transport already handles them; needs counts |
| 2 | **Yamaha DM3** | OSC over UDP 49900 | Official Yamaha spec | Medium | Documented, get/set, new and popular |
| 2 | **Yamaha TF, CL, QL** (and Rivage) | Yamaha RCP, text over TCP 49280 | Official for CL/QL/Rivage; TF partial, *unverified* | Medium | Text protocol with get, set and change notifications |
| 2 | **Allen & Heath SQ, Qu (incl. Qu 5/6/7), CQ** | MIDI (NRPN + SysEx) over TCP 51325 | Official A&H MIDI protocol PDFs | Medium–large | Documented, but MIDI-shaped and only one TCP MIDI client at a time |
| 3 | **Behringer WING** (Full, Rack, Compact) | OSC UDP 2223, or binary "native" TCP 2222 | Community (Maillot); Behringer partial | Large | Very different parameter tree; OSC needs subscriptions |
| 3 | **PreSonus StudioLive Series III** | UCNET, proprietary over TCP 53000 | None (reverse engineered) | Large, risky | Undocumented, can change with firmware |
| ✗ | Mackie DL series, Soundcraft Si/Vi (HiQnet), Roland M/V, Behringer Flow 8 (Bluetooth), DiGiCo, Midas HD/Pro | Proprietary or niche | None / not relevant | Not recommended | No public protocol, or not church-sized |

**Recommendation:** do priority 1 first (one refactor plus three small mixer families covers most small and medium
churches), then Yamaha (DM3 first: official OSC, then RCP for TF/CL/QL), then Allen & Heath. Treat WING and StudioLive
as "only if someone asks and can lend hardware".

## What has to change in the app first

The Ui24R was added by translating its protocol into XR18 addresses (`Ui24Transport` → `Ui24Map`). That works because
the Ui24R is roughly XR18-sized. It breaks down for bigger or differently shaped mixers, because the app hard-codes the
XR18 layout:

- `Mixer.init` creates exactly 16 channels, 1 aux in, 4 FX returns, 6 buses, 4 FX sends and 4 DCAs; `Strip` has 10
  sends; mute groups are 1–4; meters are parsed as the XR18's 40-value `/meters/1` blob.
- Fader values are X AIR positions (0…1 on the X AIR taper) throughout; other mixers use dB or their own taper.
- Feature pages (EQ, gate, dynamics) read X AIR ranges from `XR18Params`.

Before adding a mixer that isn't XR18-shaped, introduce a **mixer profile** (what the connected mixer has):

1. `MixerProfile`: channel count, aux inputs, FX returns, buses, matrices, FX sends, DCAs, mute groups, and which
   features are mapped (EQ bands, gate, dynamics, snapshots, colours). The transport reports it after connecting
   (`/xinfo` model today). The XR18 profile is today's numbers, so nothing changes for it.
2. `Mixer` builds strips from the profile instead of constants; views already iterate over `channels`, `buses` and
   `dcas`, so most of them follow. `Mixer.isSoundcraft` and the hidden tabs become profile checks
   (`profile.has(.eq)`).
3. Keep **X AIR addresses as the app's internal language** (it already works, backups and undo are built on it) and
   keep one translating transport per family, like `Ui24Transport`. Extend the address space where needed
   (`/ch/17`…`/ch/32`, `/bus/7`…`/bus/16`, `/dca/5`…`/dca/8`) and meters through one neutral message instead of the
   XR18 blob layout.
4. Backups: tag each backup with the profile/model and refuse to restore one mixer's backup onto another family.
5. `AutoTransport` probes each family in parallel today (XR18 + Ui). With more families, probe by port in discovery
   and remember the family per address, so a connect doesn't open five connections.

This refactor is the main cost; each XR18-shaped family after it is small.

## Family notes

### Behringer X32 / Midas M32 — recommended

- **Protocol:** OSC over UDP **10023**, the same dialect as X AIR: `/xinfo`, `/xremote` (10 s lease), `/meters`,
  `/ch/01/mix/fader`, `/ch/01/mix/on`, `/ch/01/config/name`, `/dca/1/fader`, `/config/mute/1`.
- **Differences:** 32 channels, 8 aux ins, 8 FX returns, 16 buses (`/bus/01`…`/bus/16`, two digits), 6 matrices, 8 DCAs,
  6 mute groups, main is `/main/st` (and `/main/m` mono) instead of `/lr`, headamps are `/headamp/000`…, sends are
  `/ch/01/mix/01…16/level`, meters `/meters/0`…`/meters/16` with different layouts. Same fader taper as X AIR.
- **Docs:** Patrick-Gilles Maillot's "Unofficial X32/M32 OSC Remote Protocol" (very complete); the app's existing
  `xr18_*` tools and `fake_xair.py` can be adapted.
- **Fit:** an `X32Transport` that rewrites a handful of address prefixes, plus the profile refactor for 32 channels and
  16 buses. Highest value for the effort.

### Behringer XR12 / XR16, Midas MR12 / MR18 — recommended

Same protocol as the XR18 and they already connect. XR12 has 12 channels (4 buses), XR16 16 channels (4 buses), MR18
equals XR18. Only needs the profile, so strips that don't exist aren't shown and sends to missing buses aren't
offered. `/xinfo` gives the model.

### Soundcraft Ui12 / Ui16 — recommended

`Ui24Transport` already reads the model (`ui12`, `ui16`) and switches gain addresses. Ui12: 8 inputs, 4 auxes, no VCAs;
Ui16: 12 inputs, 6 auxes, no VCAs. Needs the profile so the missing strips and the DCA row are hidden.

### Yamaha DM3

- **Protocol:** OSC over UDP **49900** (up to four OSC controllers). Addresses wrap Yamaha's parameter names:
  `/yosc:req/set/MIXER:Current/InCh/Fader/Level/1/1 -32768` (`set` / `get`, X and Y indexes, levels in 1/100 dB).
- **Docs:** official "DM3 OSC specs" from Yamaha.
- **Fit:** a `YamahaOSCTransport` mapping X AIR addresses to `MIXER:Current/...` names, dB ↔ X AIR taper. DM3 is
  16 mono + 1 stereo inputs, 6 mix buses, 2 matrices, DCAs: roughly XR18-sized, so it fits even before the full
  refactor. Check how change notifications from the console reach a remote (subscription or polling).

### Yamaha TF, CL, QL (and Rivage)

- **Protocol:** Yamaha remote control protocol (RCP/SCP): plain text lines over TCP **49280**:
  `set MIXER:Current/InCh/Fader/Level 0 0 -1000`, `get …`, and the console pushes `NOTIFY set …` when something
  changes. Easy to parse, has get, so the app can read state like on the XR18.
- **Docs:** official spec documents for CL/QL/Rivage (and the same protocol family for MTX/MCP products). TF support
  is partial and *unverified*: confirm which parameters a TF answers to.
- **Fit:** one `YamahaRCPTransport` for TF/CL/QL. TF1/TF3/TF5 are 16–40 channels with up to 20 aux buses, so it needs
  the profile refactor. Medium effort once the profile exists.

### Allen & Heath SQ, Qu, CQ (and dLive / Avantis)

- **Protocol:** MIDI messages carried over TCP **51325** (dLive uses 51328): faders, mutes, sends and pans as NRPN
  sequences, names and some state as SysEx. SQ and Qu support "get" requests; CQ has its own documented subset.
- **Limits:** the documents say **only one TCP MIDI connection at a time**, so Holly Mixer would block other MIDI
  controllers (A&H's own apps use a separate protocol and still work). No meters over MIDI, so the app would show no
  meters on these.
- **Docs:** official A&H "MIDI Protocol" PDFs for Qu, Qu-5/6/7, SQ, CQ.
- **Fit:** an `AHMIDITransport` that builds/parses NRPN; level scales are in A&H's own tables. Medium–large effort,
  and no meters is a visible gap for this app.

### Behringer WING

- **Protocol:** OSC over UDP **2223** with a different tree (`/ch/1/fdr` in dB, `/ch/1/mute`), and a
  subscription to receive changes (reportedly a keep-alive every ~9 s to a return port); or the binary "native"
  protocol over TCP **2222** that Behringer's own apps and Mixing Station use (needed for meters).
- **Docs:** Maillot's "WING remote protocols" (community, detailed); Behringer only partial.
- **Fit:** large: 48 channels, different routing model, and the reliable route is the binary protocol. Only worth it
  with a WING to test on.

### PreSonus StudioLive Series III

- **Protocol:** UCNET, proprietary, over TCP **53000** (what UC Surface uses), discovery over UDP broadcast.
- **Docs:** none official. Community projects (a Node.js API, an experimental MCP server tested on one firmware)
  show it works but mark many values as inferred.
- **Fit:** large and fragile: a firmware update can break it, and there is no specification to check against.

### Not recommended

- **Mackie DL series:** proprietary, only partly reverse engineered; no public spec.
- **Soundcraft Si / Vi:** HiQnet (Harman, proprietary); Si Expression has limited MIDI only.
- **Roland M / V-Mixing, DiGiCo, Midas HD96 / Pro:** proprietary or OSC aimed at large touring consoles, not church
  installs.
- **Behringer Flow 8:** Bluetooth LE with an undocumented protocol, and Holly Mixer is built around the network.

## How to add one family safely

1. A fake server first (`tools/fake_<family>.py`, like `fake_xair.py` and `fake_ui24.py`) so the transport can be
   built and tested without the console.
2. A translating transport plus its profile; unmapped features hidden through the profile.
3. A short hardware session following a checklist like the one in `docs/SOUNDCRAFT_UI24.md` before calling it
   supported.
4. Update the design canvas, manual and README in the same change (CLAUDE.md).

## Sources

- [CQ MIDI Protocol v1.2.0](https://www.rentex.com/wp-content/uploads/2025/03/CQ_MIDI_Protocol_V1_2_0_iss4.pdf),
  [Qu MIDI Protocol v1.9](https://www.allen-heath.com/content/uploads/2023/06/Qu_MIDI_Protocol_V1.9.pdf),
  [Qu-5/6/7 MIDI Protocol](https://www.allen-heath.com/content/uploads/2025/06/Qu567_MIDI_Protocol_Iss2.pdf)
- [Yamaha DM3 OSC specs](https://europe.yamaha.com/files/download/other_assets/2/2063222/DM3_osc_specs_v100_en.pdf),
  [Yamaha remote control protocol spec (CL/QL)](https://jp.yamaha.com/files/download/other_assets/5/1307805/pc_remote_control_protocol_spec_v102_rev3_jp.pdf),
  [Yamaha MCP2 remote spec (TCP 49280)](https://usa.yamaha.com/files/download/other_assets/9/2935299/MCP2-remote-V100-en.pdf)
- [WING Remote Protocols v3.0.6 (Maillot)](https://cdn.mediavalet.com/aunsw/musictribe/M7u1XZvRGkWxJAVwCKE5BA/7qQ-l43rn0SEnqyb5ZcETg/Original/WING%20Remote%20Protocols_V3.0.6-30.pdf),
  [WING OSC forum thread](https://behringer.world/viewtopic.php?p=1735)
- [presonus-studiolive-mcp (UCNET, TCP 53000)](https://glama.ai/mcp/servers/zarfld/presonus-studiolive-mcp)
- X32/M32: Patrick-Gilles Maillot, "Unofficial X32/M32 OSC Remote Protocol" (not re-fetched for this note).
- Soundcraft Ui: [soundcraft-ui-connection](https://github.com/fmalcher/soundcraft-ui), see `docs/SOUNDCRAFT_UI24.md`.
