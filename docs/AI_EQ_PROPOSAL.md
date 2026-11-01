# AI EQ inside Holly Mixer: proposal

Status: the **tools** exist and run from a terminal (also on an iPad); the **in-app** version is not built yet.

| Step | Tool | Needs |
|---|---|---|
| Review the EQ in force | `tools/xr18_eq_audit.py` (rules only) | the mixer on the network |
| Record a service: RTA spectrum + levels + the EQ at that moment, saved to `eq_sessions/` | `tools/xr18_eq_record.py` | the mixer; one RTA source per recording |
| Analyse the recordings and propose an EQ (local rules; with `--ai` also Claude) | `tools/xr18_eq_suggest.py` | `ANTHROPIC_API_KEY` for `--ai` |

The suggestion JSON (`eq_suggestions-*.json`) uses the shape an in-app version would use. The guard rails are the
ones described below and are enforced in code, whatever the model returns. Open points: the RTA bin axis (assumed
log, 20 Hz-20 kHz) must be checked on the real mixer, and the RTA source can only be chosen from X-AIR-Edit
(`/-prefs/rta/source` does not answer on the XR18, see `XAIR_PROTOCOL_NOTES.md`).

## What is worth building

An **EQ assistant on the channel's EQ tab** that looks at the strip and proposes a change the user can preview and
apply or discard. It does not touch the mixer by itself.

Three levels, in the order they should be built:

1. **Rule checks (no AI, no network)**. The same rules as `xr18_eq_audit.py`, ported to Swift: "low cut missing on a
   voice", "narrow boost +8 dB: feedback risk". Shown as small hints under the graph. Cheap, instant, works offline
   in the church with no internet.
2. **Suggest from name + context (AI)**. Input: channel name, current EQ (frequency/gain/Q per band, low cut), what
   the other channels carry, and a short goal chosen by the user ("clearer voice", "less boomy", "fix feedback").
   Output: a list of bands in real units. The app shows the suggested curve over the current one and the user taps
   *Apply* (one undo step, like Flatten) or *Cancel*.
3. **Suggest from what the room is doing (AI + RTA)**. Same, plus the spectrum of the channel, read from the mixer's
   RTA (`/meters/4`, 100 bins; see `ROADMAP.md` item 9). This is the only level that hears the actual sound; levels
   1 and 2 only know the numbers and the name. It also enables "ring out the monitors" (`PLAN.md`: feedback
   assistant) by finding the ringing frequency.

## Where the AI runs

| Option | For | Against |
|---|---|---|
| **Claude API, called from the app** | best suggestions, no model to ship, works for every goal in plain language | needs internet at the venue and an API key; sound data and channel names leave the device |
| **Apple on-device model (Foundation Models)** | offline, private, free | smaller model, needs a recent iPad/iPhone with Apple Intelligence; weaker at audio reasoning |
| **Rules only** | offline, deterministic, nothing leaves the device | not "AI": can't take a free-text goal or weigh the spectrum |

Recommendation: ship level 1 first (rules, offline), then level 2 behind an opt-in switch in Settings that uses the
Claude API, with the on-device model as a fallback when there is no connection. Keep the rules even when the AI is
on: they validate whatever the model returns.

## Guard rails (these matter more than the model)

- The model **proposes**; the app **validates and applies**. Output is a fixed JSON schema (`bands: [{type, hz,
  gain_db, q}]`, `low_cut_hz`). Anything outside the mixer's ranges (20 Hz–20 kHz, ±15 dB, Q 0.3–10, band count 4 or
  6) is clamped or rejected, never sent raw to OSC.
- Cap the change: at most ±6 dB per band on the first suggestion, no suggestion that adds more than +9 dB in total,
  never an EQ boost on a monitor bus between 1 and 4 kHz (feedback zone).
- Always a preview, always one undo step, and a safety backup is already made by the existing backup system before
  big changes. Never apply while the user is dragging a fader or in Musician mode.
- Show *why* each band exists ("cut 350 Hz: boxy sound on voices") so it teaches instead of being a black box.
- Privacy: send only channel names, EQ numbers and (level 3) spectrum bins, never the IP, mixer name or backups.
  API key stored in the Keychain, entered by the user; no key shipped inside the app.
- Costs and failure: one short request per tap, 10 s timeout, and when it fails the rule hints still work.

## What this touches in the code (when built)

- New `EQAdvisor.swift` (rules + request/response types), pure logic, unit-testable like `EQMath.swift`.
- `ChannelDetailEQ.swift`: an "Assist" button in the header next to *Flatten…*, a preview curve drawn by
  `EQGraphCanvas`, an Apply/Cancel bar. Strings in English and Spanish (`es.lproj/Localizable.strings`).
- `Settings`: an opt-in switch and the key field. `DemoSeeds`/`ScreenshotMode`: a demo suggestion for screenshots.
- **Design sync (CLAUDE.md):** the Channel board (`Channel.dc.html`), the Settings board, `docs/MANUAL_ES.md` and the
  README must be updated in the same task as the UI.

## Open questions for the owner

1. Is internet normally available at the church, and is sending channel names and EQ numbers to the Claude API
   acceptable? (Decides between API and on-device.)
2. Is level 3 (real spectrum) wanted? It needs the RTA work first and is the biggest improvement in quality.
3. Which iPads/iPhones must be supported? Foundation Models needs recent hardware.
