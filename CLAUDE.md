# Holly Mixer

SwiftUI iPad/iPhone remote for Behringer X AIR (XR18) mixers. App code is in `HollyMixer.swiftpm/`.

## Design must always match the code

The design canvas (<https://claude.ai/artifact/PPXZrgcLAaJeTHP5HcnSFw>) and the code must describe the same app.
Whenever you add, change or remove a screen, control or label, update the matching board in that canvas **in the same
task** (publish to the same URL, never a new canvas), then the manual (`docs/MANUAL_ES.md`) and README.
Screen ↔ board map and workflow: `docs/DESIGN_SYNC.md`. If the canvas can't be reached, say so in your summary instead
of skipping it silently.

## Working notes

- Build: `xcodebuild build -scheme HollyMixer -destination 'platform=iOS Simulator,...'` from `HollyMixer.swiftpm/`.
- The app is localized in English and Spanish (`es.lproj/Localizable.strings`, English text = key): add both.
- Debug builds accept `SIMCTL_CHILD_HM_SHOT=<screen>` (see `ScreenshotMode.swift`) for screenshots with the demo mixer.
- `tools/fake_xair.py` is a fake mixer for connection/restore testing (`docs/FAKE_MIXER.md`).
- Live-control performance: views must not read values that change at meter rate (`Strip.meter`, `peak`) or on every
  fader tick (`Mixer.liveValues`, which is `@ObservationIgnored`) in a big `body`; read them in a small child view
  (see `StripMeters`), or the whole strip row re-renders.
- A `DragGesture` on a view that moves under the finger (fader cap, EQ dot) must use a fixed `coordinateSpace:`
  (see `FaderView.dragSpace`), or the translation shrinks and the control lags behind the finger.
- Device install needs `DEVELOPMENT_TEAM=27322XSMN7` and bundle id `com.mfuentesg.hollymixer`.
