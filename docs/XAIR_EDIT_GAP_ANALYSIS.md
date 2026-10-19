# What the official X-AIR-Edit has that Mixit does not

Source: X-AIR-Edit 1.8.1 for macOS (universal Mach-O). Inspected with REA (`rea inspect-macho`, evidence
`sha256 6294054c…c96d96`) and with the string table of the arm64 slice (`strings`), to list the OSC addresses
the official app is built to talk to. Hopper was not used to decompile code, so this shows *which* parts of the
mixer the official app controls, not *how* each screen behaves. Verify each item on a real XR18.

Binary facts (from REA): arm64 + x86_64, built with the macOS 14.2 SDK, minimum macOS 11.0.

## Address families found in the binary

| Family | Strings | Meaning |
| --- | --- | --- |
| `/ch/NN/...` | 448 | per-channel: `automix`, `config` (incl. `rtnsrc` USB return source), `dyn` (+`/filter`), `eq/N`, `gate` (+`/filter`), `grp`, `insert`, `mix` (+`/N` sends), `preamp` (+`/rtnsw`) |
| `/-stat/...` | 205 | `solosw`, `rta`, `tape`, `usb/N` (USB recorder / player state) |
| `/routing/...` | 128 | `main/N`, `aux/N`, `p16/N` (P16 ULTRANET outputs, with source names like `Ch01 IN`, `Bus1 IN`, `U01 IN`) |
| `/rtn/...` | 97 | aux return and the 4 FX returns: `config`, `eq/N`, `grp`, `mix`, `preamp` |
| `/bus/N/...` | 84 | `config`, `dyn`, `eq/N`, `geq`, `grp`, `insert`, `mix` |
| `/-snap/N` | 65 | the mixer's own 64 snapshot slots (`save`, `load`, `delete`, name) |
| `/headamp/NN` | 24 | preamp gain and phantom power |
| `/lr/...` | 13 | `config`, `dyn`, `eq/N`, `geq`, `insert`, `mix` |
| `/fxsend/N` | 12 | FX send masters |
| `/-prefs/...` | 12 | `name`, `rta`, `lan` / `is` / `ap` network settings |
| `/meters/N` | 10 | meter banks |
| `/fx/N`, `/fx/N/par` | 8 | the 4 FX slots and their parameters |
| `/dca/N`, `/config/...` | 8 + 7 | 4 DCA groups; `amixenable`, `amixlock`, `buslink`, `chlink`, `linkcfg`, `mute`, `solo` |

## What Mixit already covers

Faders, mutes, pan, solo; bus and FX-send levels per channel; names, colours, icons and input source (in the
backup); preamp gain, +48V, polarity, low cut; gate and dynamics (all fields); EQ (4 or 6 bands); mute groups;
meters (bank 1); scenes stored in the app; settings backup and restore.

## Missing, in the order they matter for a church team

1. **Mixer snapshots (`/-snap/N`)** — DONE in code, verify on hardware: save, load and name the XR18's own 64 snapshots. The design's "All 64
   snapshots" button refers to these. Worth offering as a second layer next to Mixit's scenes.
2. **FX rack (`/fx/N`, `/fx/N/par`, `/fxsend`, `/rtn`)**: choose the effect type and edit its parameters for
   the 4 slots; edit returns (they have EQ and preamp-style config).
3. **DCA groups (`/dca/N`) and group assignment** — DONE: faders, mute and membership (the rest of this line is the original note):
    (`/ch/N/grp`, `/bus/N/grp`, `/rtn/N/grp`)**: four DCAs exist on
   the XR18. An earlier note in the roadmap said it has none; that was wrong.
4. **Routing (`/routing/main|aux|p16`)**: USB / ULTRANET output sources and main/aux routing.
5. **Graphic EQ on buses and Main (`/bus/N/geq`, `/lr/geq`)**: the 31-band GEQ.
6. **Sidechain filters (`/ch/N/gate/filter`, `/ch/N/dyn/filter`)**, **inserts (`/ch/N/insert`)** and
   **Automix (`/ch/N/automix`, `/config/amixenable`, `/config/amixlock`)**.
7. **Linking (`/config/chlink`, `/config/buslink`, `/config/linkcfg`)**: stereo-linked channel pairs.
8. **USB recorder (`/-stat/usb`, `/-stat/tape`)** and **solo options (`/config/solo`)**.
9. **RTA (`/-stat/rta`, `/-prefs/rta`)** and meter banks other than bank 1.
10. **Mixer preferences (`/-prefs`)**: the mixer's name and its network settings.

## How to confirm

- Open the official app against the demo or a real XR18 and compare the page list with the families above.
- For exact value ranges and enumerations, decompile with Hopper (REA `analyze` / `decompile`) the functions that
  reference these strings, or capture the app's traffic with REA's packet tools while using each screen.
