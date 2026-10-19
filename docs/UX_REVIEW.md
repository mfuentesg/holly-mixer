# Holly Mixer UX review

Date: 2026-10-19. Scope: every screen of the app as built from `main` (a859a75), iPad Pro 13" and iPhone 15 Pro
simulators, demo mixer, Spanish UI. The evidence is either `File.swift:line` in `HollyMixer.swiftpm/` or a screenshot
name (taken with the `HM_SHOT` debug hook and kept outside the repo: `ipad-main`, `ipad-bus2`, `ipad-channel-EQ`,
`ipad-channel-Input`, `ipad-channel-Config`, `ipad-master`, `ipad-settings`, `ipad-mutegroups`, `ipad-backups`,
`ipad-snapshots`, `ipad-pairing`, `ipad-connect`, `iphone-main`, `iphone-bus2`, `iphone-channel-EQ`,
`iphone-channel-Input`, `iphone-channel-Config`, `iphone-settings`, `iphone-mutegroups`, `iphone-monitor`,
`iphone-monitor-free`, `iphone-connect`, `iphone-land-main`).

These decisions are already made and this review does not reopen them: no banks, a visible Settings button, mute
groups in the footer, no scenes, the graphite theme.

---

## (a) Summary: the 5 highest-impact changes

1. **Show the volunteer what is silencing a channel.** A channel that is in an active mute group or a muted DCA still
   looks live: green name, grey MUTE, moving fader. Nothing in `ChannelStripView` or `PhoneChannelRow` reads
   `muteGroupMask` or `dcaMask`. This is the classic "why is there no sound?" trap during a service. The footer group
   buttons also show only `1 2 3 4`, so nobody can tell what a group silences. Fix: give the groups names and member
   counts in the footer, and add a "silenced by group / DCA" state on each strip.
2. **Make monitor (sends) mode safe.** In a bus mix the strip MUTE still sends `/ch/xx/mix/on`
   (`Mixer.swift:558-566`). A volunteer who wants to take the pastor out of the drummer's in-ears mutes the pastor
   for the whole room. On iPhone, sends mode has no banner and no "Back to Main" (`iphone-bus2`, only the title and
   the fader colour change), so it is easy to forget which mix you are in.
3. **Add the missing Main LR on iPhone portrait, and stop accidental level jumps on phones.** The iPhone list has
   no Main LR fader, mute or meter (`PhoneMixerView.swift:126-134`). The horizontal fader grabs any touch that starts
   on its cap and has no direction lock (`PhoneHorizontalFader.swift:70-76`), so scrolling the list can move faders.
   On every fader, double-tapping *anywhere* on the track jumps the level to 0 dB (`FaderView.swift:67-72`,
   `PhoneHorizontalFader.swift:48-53`). Knobs inside scrolling pages (the 110 pt preamp GAIN, the EQ and dynamics
   knobs) take vertical drags too (`Knob.swift:88`).
4. **Close the musician-mode escape hatch.** "Hold to exit" (2 s) plus one confirm drops the musician's phone into the
   full mixer, with mutes, +48V and every channel (`PhoneMonitorView.swift:115`, then `PhoneViews.swift:14-20`). The
   manual-entry form lets the musician choose "Free" switching for themselves (`MonitorPairingScanner.swift:198-200`).
   On top of that, a musician cannot pair at all until their phone is connected to the mixer, because "Pair as
   musician" lives only in Settings, which you reach only after connecting.
5. **Make navigation predictable and the same on both devices.** Today:
   - Opening a channel needs a hidden "tap, then tap again" on iPad (`ChannelStripView.swift:154-159`) and one tap on
     iPhone.
   - Every sub-page's back button returns to the mixer, even pages opened from Settings (`PlaceholderScreen.swift:31-33`).
   - The iPhone channel page has no fader or mute (except in Config) and no previous/next arrows, and its "Listo" button
     truncates to "Li…" (`iphone-channel-*`).

   Fix: one tap opens a channel, back returns to where you came from, and the iPhone channel page gets a pinned fader
   and mute row.

---

## (b) Prioritized findings

P0 = can cause a live mistake or leaves a core job undoable, fix before the next service. P1 = high friction or
confusion. P2 = polish.

| # | Pri | Screen | Problem (evidence) | Proposed change | Effort | Risk |
|---|---|---|---|---|---|---|
| 1 | P0 | iPad and iPhone mixer | A channel silenced by an active mute group or a muted DCA looks fully live. No strip reads group or DCA state (`ChannelStripView.swift:20-31`, `PhoneMixerView.swift:190-216`); in `ipad-main` group 1 holds 7 channels and none of them carries a marker. | When a strip is silenced by a group or DCA: dim the fader line, outline MUTE in red with a small tag (`G1` or `DCA2`), and add the VoiceOver value "silenciado por Grupo 1". The data is already there: `muteGroupMask`, `muteGroups`, `dcaMask`, `DCAGroup.isOn`. | M | Low |
| 2 | P0 | Footer (iPad), bottom bar (iPhone) | The mute group buttons show only `1 2 3 4` (`MixerView.swift:500-517`, `PhoneMixerView.swift:157-174`). A volunteer cannot know that "1" means "the band". The XR18 has no names for mute groups (`MANUAL_ES.md:316`). | Store a name per group in the app (per mixer, and include it in backups) and show `Banda · 7` on each button. Unnamed groups with no members show greyed "Vacío". Add a name field to each card in Settings › Mute groups. | M | Low |
| 3 | P0 | iPad sends mode, iPhone sends mode | In a bus mix the strip MUTE still mutes the channel everywhere (`ChannelStripView.swift:141-146` → `Mixer.swift:558-566`). The banner says "faders are sends" but says nothing about the buttons (`ipad-bus2`). | **Option A (recommended):** in sends mode the button becomes `QUITAR` / "quitar del retorno". It sets the send to −∞ and remembers the previous level for a second tap. The app has no per-send on/off address (`Strip.swift:33` only knows `mix/NN/level`), so this lives in the app. **Option B:** keep the room MUTE but relabel it `MUTE SALA` and ask for confirmation in sends mode. A is safer and matches the volunteer's intent. | M | Medium: needs a remembered level per send and an undo entry |
| 4 | P0 | iPhone mixer (portrait) | No Main LR fader, mute or meter anywhere in the list (`PhoneMixerView.swift:126-134`; `iphone-main`). The iPad pins Main on the right (`MixerView.swift:50`). | Pin a compact Main LR row (fader, MUTE, stereo meter) above the mute group bar, always visible. In a bus mix the same pinned row becomes that bus's master, and the "MASTER" section at the end of the list (`:131-134`) goes away. | S | Low |
| 5 | P0 | iPhone mixer | Sends mode is shown only by the title and blue fader lines (`iphone-bus2`). There is no banner and no "Back to Main"; the iPad has `SendsBanner` (`MixerView.swift:17-20`). | Reuse a slim one-line `SendsBanner` under the header: "Faders = envíos a IEM Batería · [Volver a Sala]", tinted with the bus colour, on iPhone portrait too. | S | Low |
| 6 | P0 | iPhone faders | `PhoneHorizontalFader` starts dragging on any touch on the cap (`minimumDistance: 0`) and has no direction lock (`PhoneHorizontalFader.swift:70-76`). The iPad fader waits for a clear direction (`FaderView.swift:89-96`). A vertical scroll that starts on a cap moves the level. | Port the iPad rule: wait for 6 pt of movement, and if the movement is mostly vertical, hand it to the scroll view. Widen the cap's hit area to 56 pt so a deliberate grab is easy. | S | Low |
| 7 | P0 | All faders | Double-tapping anywhere in the fader area (not just the cap) sets 0 dB (`FaderView.swift:67-72`, `PhoneHorizontalFader.swift:48-53`). A stray double tap on a channel at −30 dB is a +30 dB jump, which can cause feedback. | Limit double-tap reset to the cap, and never reset from −∞, or ignore double taps while the level is under −40 dB. Keep the undo entry. | S | Low |
| 8 | P0 | Channel page (iPhone, and iPad cards) | `ParamKnob` takes a vertical drag (`minimumDistance: 2`, `Knob.swift:88`) inside a `ScrollView` (`ChannelDetailSections.swift:9`). On iPhone the preamp GAIN dial is 110 pt wide (`:51-54`, `iphone-channel-Input`), so scrolling the Input page can change gain (−12 to +60 dB over 180 pt). Confirm on a device. | Make knobs take a drag only after a short hold (0.15 s) or after a clear vertical move. Show a dB bubble while dragging, as the faders do. On iPhone, give GAIN a [−] [+] stepper (1 dB per tap) next to the dial. | M | Medium: test the gesture conflict on a real device |
| 9 | P0 | Musician mode | Exiting (hold 2 s, then confirm) shows the full mixer on the musician's phone (`PhoneMonitorView.swift:77-82,115`; `PhoneViews.swift:14-20`). Manual pairing lets the musician pick "Libre" (`MonitorPairingScanner.swift:198-200`). | **Option A (recommended):** exit needs a 4-digit PIN that the sound lead sets on the iPad pairing page. Carry it in the QR code as a hash, and reuse `ServicePINSheet`, which already exists. **Option B:** exit disconnects and returns to Connect. That is weak, because the found mixer is one tap away. Also remove the switching picker from manual entry: manual pairing is always "Bloqueado". | M | Low |
| 10 | P1 | iPad header, Settings | The power icon disconnects at once, with no confirmation (`MixerView.swift:142-144`, `SettingsHubView.swift:37-40`). It sits 44 pt from Settings. | Ask for confirmation: "¿Desconectar? La consola sigue sonando; solo esta app deja de controlarla." Better: move Disconnect only into Settings, which already has it, and drop it from the header. | S | Low |
| 11 | P1 | iPad mixer | Opening a channel needs a tap to select and a second tap to open (`ChannelStripView.swift:154-159`). Selection has no other use on the main screen (it only gates the second tap). The manual has to explain it (`MANUAL_ES.md:182`). The iPhone opens with one tap (`PhoneMixerView.swift:256`). | **Option A (recommended):** one tap on the name opens the channel page, as on iPhone. Remove the selection highlight. **Option B:** keep selection and show an "Abrir ›" chip on the selected strip. A removes a concept; B adds UI. | S | Low |
| 12 | P1 | All sub-pages | The back button always closes everything (`PlaceholderScreen.swift:31-33`), labelled "Consola". Settings › Mute groups › back lands on the mixer, not on Settings. | Present Settings as a `NavigationStack` and push Mute groups, Backup, Snapshots and Pairing inside it, so back means back. Keep the channel page as a full-screen cover with one close button. | M | Low |
| 13 | P1 | Channel page (iPhone) | No fader, mute or solo except inside the Config tab (`ChannelDetailView.swift:56-59` shows the side fader only on regular width). No previous/next (`:97`). Title and "Listo" truncate: "Guitarra…", "Li…" (`iphone-channel-EQ`). Tabs scroll off-screen: Envíos and Config are hidden. | Pin a 56 pt bottom bar: [M] [S] horizontal fader, dB. Put ‹ › in it. Use an ✕ icon instead of "Listo" (one close control, not two), and let the title take the remaining width. Use a segmented tab bar that fits 6 short labels, or two rows. | M | Low |
| 14 | P1 | iPhone mixer | No solo indicator. The iPad has a "SOLO · Quitar" pill (`MixerView.swift:99-118`); the iPhone header has none (`PhoneMixerView.swift:54-67`). A solo on a channel scrolled out of view is invisible. | Show the same amber pill under the mix title whenever `soloedStrips` is not empty. | S | Low |
| 15 | P1 | iPhone reconnect | The phone shows only a 28 pt text strip and no "Reintentar" (`PhoneMixerView.swift:18-25`). The iPad has the full banner and retry (`MixerView.swift:453-487`). | Use the same `ReconnectingBanner` (one line) on iPhone and in musician mode (`PhoneMonitorView.swift:50-58`). | S | Low |
| 16 | P1 | Mute groups page | Member chips are filled red, the same colour as "muted" (`MuteGroupsView.swift:83`; `ipad-mutegroups`), so the edit page looks like half the band is muted. A live "Silenciar este grupo" button sits on the edit page (`:43-55`). The iPhone page is one 100+ chip scroll (`iphone-mutegroups`). | Show members as an accent outline with a ✓ (neutral), and keep red only for "the group is muted now". Remove the fire button from the edit page (the footer is the place to fire). On iPhone, show one group at a time with a 1-4 segmented control at the top. Also show the group's name field (item 2). | S | Low |
| 17 | P1 | iPad strips | The gate "G" pill never appears. `C` has `layoutPriority(1)` and both pills are `maxWidth: .infinity`, so C takes the whole width (`ChannelStripView.swift:192-194`; `ipad-main` shows only "C"). | Give both pills a fixed equal width (e.g. 28 pt each). | S | Low |
| 18 | P1 | iPad mixer | The DCAs (Banda, Voces, Pastor, Playback) are the most useful faders for a volunteer, but they come last, after 26 strips (`MixerView.swift:33-39`). | **Option A (recommended):** pin the four DCAs as a narrow group on the right, next to Main, in Main LR mode (they are not part of bus mixes). **Option B:** put the DCAs first in the row. A keeps them always visible but costs about 4×60 pt; on iPad 11" portrait, use B. | M | Medium: width on smaller iPads |
| 19 | P1 | Backup banner → restore | The banner's "Revisar y restaurar" opens the Backup page, which shows the same card and the same button again (`BackupView.swift:77-79` → `:207-240`). That is 4 taps to restore. | The banner button opens `BackupReviewSheet` for `pending.backup` directly (3 taps). | S | Low |
| 20 | P1 | Snapshots | "Cargar", the most disruptive action in the app, is the most prominent button on every row (`SnapshotsView.swift:126-137`; `ipad-snapshots`). The footer says the commands "still need to be checked on a real mixer" (`:37`). 59 of the 64 rows are "Vacía". | Hide Snapshots behind a feature flag until they are verified on hardware (as `FeatureFlags.serviceMode` does). After that: make Load secondary with a hold-to-load (`HoldToRecallButton` exists), and collapse the empty slots under "Mostrar ranuras vacías". | S | Low |
| 21 | P1 | Undo | One tap undoes the newest change from any time in the session, with no feedback (`MixerView.swift:268-270`, `Mixer.swift:780-785`). The list items are not tappable. Mute entries are hard-coded English: "Pulpito muted" (`Mixer.swift:565`). | After undo, show a 3 s toast: "Deshecho: Pulpito fader −2.0 dB · Rehacer". Localize the history labels. Optionally grey out entries older than 10 min. | S | Low |
| 22 | P1 | iPhone landscape | SOLO/MUTE are 34 pt tall and about 33 pt wide each (`ChannelStripView.swift:91,134,142`). The footer group buttons are 34 pt (`MixerView.swift:508`). The fader scale labels collide (`iphone-land-main`). | Keep MUTE at 44 pt; drop SOLO in landscape, or make it a long-press on MUTE. Show only the 0 / −10 / −30 / ∞ marks on short faders. | S | Low |
| 23 | P1 | Connect | The musician has no path from this screen: pairing is only in Settings, after connecting. On iPad the empty-state text truncates to "…esté en l…" (`ConnectView.swift:89-95`; `ipad-connect`). | Add a second card under the demo: "Soy músico: escanear el código del iPad" (opens `MonitorPairingScannerSheet`). Add `.fixedSize(horizontal: false, vertical: true)` to the empty-state text. | S | Low |
| 24 | P1 | iPad header (portrait, narrow iPads) | Known "S a" squeeze. In the header HStack, `ConnectionPill` is `fixedSize()` but the name block and the "Exit demo" button are not (`MixerView.swift:87-95,130-140`), so they are the first to shrink when the SOLO pill appears. Not reproduced on 13" (`ipad-main`). | `fixedSize()` and `layoutPriority(2)` on the exit button; `layoutPriority(1)` on the name. Below 900 pt width, hide the model/firmware line and the stereo meter (Main is already metered on the master strip). | S | Low |
| 25 | P2 | iPad strip chrome | About 170 pt per strip goes to an EQ thumbnail, G/C pills, a pan arc and a header (`ChannelStripView.swift:31-43`); none of it is editable, and it takes fader travel. | Merge the EQ thumbnail, G/C and pan into one 22 pt "status" row (tiny EQ curve plus G·C dots, pan as a number). That gives about 80 pt more fader travel. | M | Low |
| 26 | P2 | Channel Config (iPad) | Two MUTE buttons and two faders on screen: the Config "Fader" card and the side column (`ChannelDetailSections.swift:421-437`; `ipad-channel-Config`). | Show the Fader card only when the side fader is hidden (compact width). | S | Low |
| 27 | P2 | Sends tab and Config fader | `ChannelLevelSlider` jumps to the touch point when you touch the track (`ChannelDetailSections.swift:180-183`), unlike the "no jump" faders. | Same relative-drag rule as the faders. | S | Low |
| 28 | P2 | Channel EQ (iPad) | Bands 5-6 of the bus and Main EQ sit off-screen with no scroll hint (`ipad-master`). | Use a 3-column grid, or fade the trailing edge as the strip row does. | S | Low |
| 29 | P2 | Accessibility | Every font is a fixed `.system(size:)`, so Dynamic Type is ignored. `textMuted` (#6E737D) is 3.7:1 on `strip` and `textDim` is 2.4-3.0:1, below the 4.5:1 that small text needs; muted channel names and off pills use them (`Theme.swift:22-23`, `ChannelStripView.swift:167`, `:257`). Tab VoiceOver labels are raw English (`ChannelDetailView.swift:221`). The Settings hint mentions the removed "Order of service" (`MixerView.swift:210`). | Raise `textMuted` to about #8A8F99 and `textDim` to about #747985. Scale text with `@ScaledMetric` on non-fader pages (Settings, Connect, Backup). Fix the labels (see section e). | M | Low |
| 30 | P2 | Onboarding | There is no in-app help, and the manual lives only in the repo. | Add an "Ayuda" row in Settings: a 4-card quick guide (mute groups, monitor mode, "why no sound?", restore). Show it once on the first connection. | M | Low |
| 31 | P2 | Docs | The manual says mute groups are hidden on narrow screens (`MANUAL_ES.md:117-118`), but the footer is always shown (`MixerView.swift:58`). It also says the group buttons are "in the top bar" (`MANUAL_ES.md:316`). | Fix both lines with the code changes. | S | None |

---

## (c) Quick wins (each under an hour)

1. Add a pinned Main LR row to the iPhone list (#4).
2. Add `SendsBanner` and the solo pill on iPhone (#5, #14).
3. Add a direction lock to `PhoneHorizontalFader` (#6).
4. Limit double-tap reset to the cap (#7).
5. Ask for confirmation on the header power button, or remove it (#10).
6. Make a single tap open a channel on iPad (#11).
7. Give the G/C pills fixed widths (#17).
8. Make the backup banner open the review sheet directly (#19).
9. Show mute-group members with a neutral outline and remove the fire button from the edit page (#16).
10. Put Snapshots behind a feature flag until they are verified (#20).
11. Remove the "Libre" picker from manual pairing (#9).
12. Add the "Soy músico" card on Connect, and fix the truncated empty state (#23).
13. Use `ReconnectingBanner` on iPhone (#15).
14. Fix all copy items in section (e).
15. Set `fixedSize`/priorities in the iPad header (#24).

---

## (d) Common task flows: taps today vs proposed

Counts start from the mixer screen with nothing open; drags count as one action; scrolling is not counted.

| Task | iPad now | iPad proposed | iPhone now | iPhone proposed |
|---|---|---|---|---|
| Mute a channel | 1 | 1 | 1 | 1 |
| Mute or ride Main LR | 1 | 1 | **impossible in portrait** | 1 (pinned row) |
| Silence "the band" | 1, but you have to know that "1" is the band | 1, labelled "Banda" | 1 (same problem) | 1, labelled |
| Find why a channel is silent | Open Settings › Mute groups and read 4 cards (≥3 taps), then check the DCAs | 0: the strip shows "G1" or "DCA2" | Same, ≥3 | 0 |
| Raise the pastor in the drummer's in-ears | chip, drag, "Volver a Main" = 3 (and you must remember to go back) | 3, with a safe QUITAR | menu, bus, drag, menu, Main = 5, and no reminder that you are in sends mode | 5, with a banner and a 1-tap "Volver a Sala" (4) |
| Take a channel out of one monitor mix | chip, MUTE (**mutes the room**) | chip, QUITAR = 2 | same hazard | 2 + back |
| Open a channel's EQ | 2 (tap, tap again; EQ is the default tab) | 1 | 1 | 1 |
| Assign a channel to a mute group | Settings, Mute groups, chip, back (lands on the mixer) = 4; or via channel: tap, tap, Config, group, Listo = 5 | Settings, Mute groups, chip, back, back = 5, or 4 via the channel | Settings, Mute groups, scroll, chip, back = 4 | Settings, Mute groups, pick group, chip = 4 |
| Restore after a mixer reset | Banner, card button, Restaurar, confirm = 4 | Banner, Restaurar, confirm = 3 | 4 | 3 |
| Clear all solos | 1 (pill) | 1 | Find every soloed row: n taps | 1 (pill) |
| Pair a musician's phone (first time) | Settings, Pairing, bus, me = 4 | 4 | Connect first (1-2), Settings, Pair, scan = 4-5 | Connect screen "Soy músico", scan = 2 |
| Leave musician mode | Hold 2 s, confirm, and you have **the full mixer** | Hold, confirm, PIN | — | — |

---

## (e) Copy and translation issues

| Where | Current (ES UI) | Problem | Proposed |
|---|---|---|---|
| `ChannelDetailSections.swift:414`, strings:589 | "Al pulsar un grupo de mute en la barra superior…" | The groups are in the **bottom** bar | "Al pulsar un grupo de mute en la barra inferior se silencian a la vez todos sus canales." (EN: "…in the bottom bar…") |
| `PhoneViews.swift:156`, strings:307 | "…luego Más > Vincular como músico…" | There is no "Más" menu any more | "En el iPhone del músico abre Holly Mixer, toca Ajustes › Vincular como músico y escanea este código." |
| `PhoneViews.swift:161-163,182-184` | "Mixer / Bus / Me" (English) | `detailLine` takes a `String`, so `Text(title)` is never translated | Use `LocalizedStringKey` or `L()`: "Consola / Retorno / Mi canal". Hide the raw `hollymixer://` URL (`:164`), or put it behind "Mostrar código". |
| `MonitorPairingScanner.swift:163,227` | "That isn't a Holly Mixer pairing code." / "Enter the mixer's address…" | Plain `String`, shown untranslated | `L("…")`: "Ese código no es de Holly Mixer." / "Escribe la dirección de la consola, por ejemplo 192.168.1.2." |
| `BackupView.swift:196` | "Nothing saved yet" / "Reading the mixer…" in English | A `String` passed to `ScreenTopBar`; the keys exist (strings:24-25) but are not used | Wrap both in `L()` |
| `Mixer.swift:565` | "Pulpito muted" in the undo list | Hard-coded English | `L("\(name) silenciado")` / `L("\(name) activado")`; EN "muted" / "unmuted" |
| strings:73 (`ChannelDetailProcessing.swift:171`, `ChannelDetailEQ.swift:176`) | "On" | English in the ES UI (`ipad-channel-EQ`, `iphone-channel-EQ`) | "Activado" |
| `ChannelDetailView.swift:221` | VoiceOver reads "Input", "Dynamics"… | `accessibilityLabel(tab.rawValue)` | `accessibilityLabel(LocalizedStringKey(tab.rawValue))` |
| `MixerView.swift:210` | Hint "Order of service, mute groups…" | Mentions the removed scenes | "Grupos de mute, copias de ajustes, snapshots, vincular músicos, idioma" |
| strings:164 | "MUEVE MIENTRAS EDITAS" | Awkward imperative | "NIVEL DEL CANAL" |
| strings:261 | "Volver a Main" | Mixes languages; volunteers say "sala" | "Volver a la sala (Main)" |
| Pairing vs monitor | "BUS" (pairing) / "Retorno" (musician) / "MEZCLA" (mixer) | Three words for one idea | Volunteer-facing text uses "Retorno" for buses 1-6 (pairing "RETORNO", sends banner "Los faders son envíos al retorno IEM Batería"). Keep "Bus N" only as the small technical label. |
| strings:305 | "Ch 12" | English abbreviation on unnamed channels | "Can. 12" (or "Canal 12" on the iPhone rows, which have room) |
| strings:334, :349, :373 | Scene/recall strings | Left over from removed features | Delete them so translators don't maintain dead text |

---

## (f) Open questions for the owner

1. **Mute group names**: are four app-side names per mixer enough (for example "Banda", "Coro", "Púlpito", "Video")?
   The XR18 can't store them, so a second iPad would see them only after importing a backup. Is that acceptable, or
   should names travel in the pairing or backup file?
2. **"Take out of this monitor"** (#3): do you want the app to remember the previous send level, or would setting the
   send to −∞ be enough for your team?
3. **DCAs**: does the volunteer team really mix with the four DCAs (Banda, Voces, Pastor, Playback)? If yes, pinning
   them next to Main (#18) is the biggest single simplification for volunteers.
4. **Musician exit PIN**: one PIN for the whole church, or per musician? Who should know it?
5. **Snapshots**: are they used today on the physical mixer? If nobody loads them during services, keep them hidden
   until they are verified on hardware.
6. **Jargon**: should the Spanish UI keep the console words ("MUTE", "Gate", "Snapshots", "Main LR", "Shelf") so it
   matches the XR18 and X AIR Edit, or use plainer words ("Silencio", "Puerta", "Memorias", "Sala")? This review
   assumes you keep the console words and add a glossary in Ayuda.
7. **iPhone landscape**: is it used by anyone? If not, locking the phone to portrait removes the cramped 34 pt
   buttons (#22) entirely.

## Implementation status (2026-10-19)

Built (with the recommended options): #1 silenced-by-group/DCA tags, #2 named groups with counts, #3 REMOVE/✕ in
monitor mixes, #4 Main LR pinned on iPhone, #5 sends banner on iPhone, #6 direction lock on the phone fader, #7
double-tap reset only from the cap and never from far below, #8 knobs need a short press (plus ±1 dB gain buttons),
#9 exit PIN for musician mode and no "Free" choice in manual pairing, #10 power button removed from the header and a
confirmation before disconnecting, #11 one tap opens a channel, #12 Settings is a navigation stack (back returns to
Settings), #13 iPhone channel page bar and fitting tabs, #14 solo pill on iPhone, #15 reconnect banner on iPhone and
in musician mode, #16 mute group members shown neutrally with names and no fire button, #17 G and C pills both show,
#18 DCAs pinned next to Main (first in the row on narrower screens), #19 backup banner opens the review directly, #20
Snapshots behind `FeatureFlags.snapshots` (off), #21 undo toast, #23 "I'm a musician" card, #24 header priorities,
#26 and #27 (Config fader card only on phones, relative drag in sliders), #29 contrast (`textMuted`, `textDim`), and
the copy fixes in (e) that applied.

Not built: #22 beyond keeping iPhone landscape fitting, #25 (merging the strip chrome), #28 (EQ band fade), Dynamic
Type in #29, #30 in-app help, and deleting the leftover scene strings (hidden Service Mode still uses some).
