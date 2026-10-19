# Holly Mixer roadmap: ideas worth building next

Ordered by value for a church sound team. Items marked (needs hardware) should be checked on a real XR18.

## Done since this list was written
Automatic restore with countdown, safety copies before risky actions, DCA groups, mixer snapshots.

## Safety and reliability
1. **Auto-restore on connect, with a countdown** (opt-in): if the mixer comes back reset, restore the last
   backup after a visible 10 s countdown with Cancel. Builds on Settings backup.
2. **Backup before every scene recall and every Service Mode start**, so one tap goes back to "before".
3. **Backup diff view**: pick two backups and see what changed between them (who touched the EQ?).
4. **Change log**: persistent list of changes made from this app with time, so "who moved the pastor's
   fader?" has an answer. Undo history is session-only today.
5. **Lock channels**: mark channels (for example the pastor's mic) as protected so a stray drag can't move them
   outside Service Mode.
6. **Feedback and clipping alerts**: highlight a channel whose meter has hit 0 dBFS in the last minute.

## Mixing
7. **DCA groups** (`/dca/1..4`) and channel-to-DCA/mute-group assignment (`/ch/NN/grp`): see the X-AIR-Edit gap analysis.
8. **Copy and paste channel settings** (EQ, gate, dynamics) between channels, and channel presets
   ("Male vocal", "Acoustic guitar") that can be applied from the channel page.
9. **RTA / spectrum view** under the EQ: `/meters/4` returns 100 RTA bins (official protocol document). Also DCA meters (`/meters/8`) and recorder meters (`/meters/9`).
10. **FX page**: the 4 FX slots with type and parameters, and their returns.
11. **Routing and USB**: input source, USB return and bus-to-main assignments.
12. **Talkback / monitor and headphones level** from the iPad.

## Workflow
13. **Soundcheck mode**: walk the channels one by one with solo, gain readout and a notes field per channel.
14. **Show notes per scene**, such as "pastor walks up after song 3", shown in the Service footer cue.
15. **Scheduled scenes**: recall "Walk-in" at 10:30 automatically with a fade (only when the iPad is awake).
16. **Multiple mixers**: switch between the main XR18 and, for example, the youth room mixer, each with its own
    show file and backups.
17. **iCloud sync** of shows and backups, so a replacement iPad has everything.

## Musicians
18. **Musician pages that follow the scene**: each iPhone shows only the channels its bus uses, and flashes when
    the sound lead changes its mix.
19. **"More me" / "less others" quick buttons** on the iPhone with a limit set by the sound lead.

## Platform
20. **Landscape iPhone layout** and iPad Split View.
21. **Haptic and VoiceOver polish**; Dynamic Type check on all pages.
23. **Widgets / Live Activity** showing the live scene and a mute-all button (needs a full Xcode app, not Playgrounds).

## Known gaps (not possible or unverified)
- **Wi-Fi signal (dBm) and "other clients"** in Check my network: iOS has no public API for the first without a
  special entitlement, and the XR18 does not list its clients.
- **Guest network detection**: Holly Mixer shows a hint when the mixer can't be seen, because reading the network
  name needs an entitlement that Swift Playgrounds can't grant.
- **Backup covers** levels, mutes, pan, sends, names, colors, icons, input source, preamp, EQ, gate and
  dynamics. FX, routing and global settings are not read yet.
