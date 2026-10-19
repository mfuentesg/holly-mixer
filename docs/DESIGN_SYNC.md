# Keeping the design in sync with the code

The source of truth for how the app should look is the design canvas:
<https://claude.ai/artifact/PPXZrgcLAaJeTHP5HcnSFw> ("Holly Mixer — iPad & iPhone UI", a Claude Design canvas,
tokens: "Graphite console", see the *System* board). The SwiftUI code is the source of truth for what is built.
**They must always describe the same app.** Any change to a screen updates both in the same piece of work.

## Screen ↔ board map

| App screen (Swift file) | Canvas board |
|---|---|
| iPad mixer: `MixerView.swift`, `ChannelStripView.swift`, `DCAViews.swift`, `FaderView.swift` | `Main.dc.html` (modes: main, sends, reconnecting, demo) · `Sends.dc.html` · `Reconnecting.dc.html` |
| iPhone mixer: `PhoneMixerView.swift`, `PhoneHorizontalFader.swift` | `PhoneMixer.dc.html` |
| iPhone channel page (`ChannelDetailView.swift`, compact) | `PhoneChannel.dc.html` |
| Musician mode: `PhoneMonitorView.swift`, `PhoneViews.swift` (pairing) | `PhoneMonitor.dc.html` |
| Channel page: `ChannelDetail*.swift` | `Channel.dc.html` (EQ tab) · `ChannelConfig.dc.html` (Config tab: name, colour, DCA, mute groups, fader) |
| Settings page: `SettingsHubView.swift` | `Settings.dc.html` |
| Help: `HelpView.swift` | `Help.dc.html` |
| Mute groups: `MuteGroupsView.swift`, footer/bottom bars | `MuteGroups.dc.html`, footer of `Main.dc.html`, bar of `PhoneMixer.dc.html` |
| Connect: `ConnectView.swift` | `Connect.dc.html` |
| Service Mode (hidden by `FeatureFlags.serviceMode`): `Service*.swift` | `Service.dc.html` (marked hidden in the board title) |
| Tokens: `Theme.swift` | `System.dc.html` |
| Alerts / confirmation dialogs (`confirmationDialog`, `.alert` in `ChannelDetailSections`, `ChannelDetailEQ`, `BackupView`, `SnapshotsView`, `PhoneMonitorView`) | `Alerts.dc.html` |
| Banners, notices, connect/permission messages, inline help (`SendsBanner`, `ReconnectingBanner`, `BackupBanner`, `MixerBackup.notice`, `ConnectView`) | `Notices.dc.html` |

Removed features (no board): Order of service / scenes.

## Workflow when a screen changes

1. Change the code, build it, look at it (simulator or device).
2. Update the matching board(s) in the canvas, using the Artifact tool's `read` on the canvas URL, editing the
   `project/*.dc.html` files and publishing to the **same URL** (never create a new canvas).
3. Add, rename or remove boards in `project/canvas.json` when a screen is added, renamed or removed.
4. Update `docs/MANUAL_ES.md` (and its screenshots, retaken with the debug `ScreenshotMode` hooks) and the README.
5. Commit code and docs together; say in the summary which boards were updated.

`/design-sync` is not used for this project: it converts a React component library, and this is a SwiftUI app.
