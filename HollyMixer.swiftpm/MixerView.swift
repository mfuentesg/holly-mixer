import SwiftUI

struct MixerView: View {
    @Environment(Mixer.self) private var mixer
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    var body: some View {
        let target = mixer.selectedMix
        let master = mixer.master(for: target)
        let control = target.control
        let busColor: Color? = target == .main ? nil : master.color
        let isReconnecting = mixer.status != .connected && !mixer.isDemo

        VStack(spacing: 0) {
            MixerHeader(isCompact: sizeClass == .compact, isShort: verticalSizeClass == .compact)
            MixSelector(isCompact: verticalSizeClass == .compact)
            if target != .main {
                SendsBanner(master: master)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if isReconnecting {
                ReconnectingBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            BackupBanner()

            HStack(spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(mixer.inputs.filter { $0.hasControl(control) }) { strip in
                            ChannelStripView(strip: strip, control: control, busColor: busColor)
                        }
                        if target == .main {
                            ForEach(mixer.buses + mixer.fxSends) { strip in
                                ChannelStripView(strip: strip, control: .fader, busColor: nil)
                            }
                            ForEach(mixer.dcas) { group in
                                DCAStripView(group: group)
                            }
                        }
                    }
                    .padding(.trailing, 40)
                }
                .overlay(alignment: .trailing) {
                    LinearGradient(colors: [Theme.background.opacity(0), Theme.background],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 56)
                        .allowsHitTesting(false)
                }
                ChannelStripView(strip: master, control: .fader, busColor: busColor, isMaster: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, verticalSizeClass == .compact ? 6 : 12)
            .opacity(isReconnecting ? 0.4 : 1)
            .saturation(isReconnecting ? 0.35 : 1)
            .allowsHitTesting(!isReconnecting)

            MixerFooter(isShort: verticalSizeClass == .compact)
        }
        .background(Theme.background.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.2), value: target)
        .animation(.easeInOut(duration: 0.2), value: isReconnecting)
        .fullScreenCover(item: Binding(get: { mixer.presentedScreen }, set: { mixer.presentedScreen = $0 })) { screen in
            PresentedScreenView(screen: screen)
                .environment(mixer)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

// MARK: - Header

struct MixerHeader: View {
    @Environment(Mixer.self) private var mixer
    let isCompact: Bool
    /// Landscape iPhone: a slimmer bar to leave room for the strips.
    var isShort = false

    var body: some View {
        HStack(spacing: 12) {
            HollyMixerLogo(size: 20)
                .frame(width: 36, height: 36)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.08), lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(mixer.mixerName.isEmpty ? mixer.host : mixer.mixerName)
                    .font(Theme.mono(14))
                    .foregroundStyle(Theme.textPrimary)
                Text(L("\(mixer.model) · fw \(mixer.firmware) · \(mixer.isDemo ? L("demo") : mixer.host)"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .lineLimit(1)

            ConnectionPill()

            if let soloed = mixer.soloedStrips.first {
                Button {
                    mixer.clearSolo()
                } label: {
                    HStack(spacing: 8) {
                        Text(L("SOLO · \(mixer.soloedStrips.count > 1 ? L("\(mixer.soloedStrips.count) channels") : soloed.displayName)"))
                            .font(.system(size: 12, weight: .bold))
                        Text("Clear")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(hex: 0xC9A64A))
                    }
                    .foregroundStyle(Theme.amberText)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Theme.solo.opacity(0.14), in: Capsule())
                    .overlay(Capsule().stroke(Theme.solo.opacity(0.45), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Solo active. Clear solo")
            }

            Spacer(minLength: 8)

            UndoButton()
            MoreMenu(showsTitle: !isCompact && !isShort)

            if !isCompact {
                MiniStereoMeter(left: mixer.main.meter, right: mixer.main.meterRight ?? mixer.main.meter)
                    .frame(width: 104)
            }

            if mixer.isDemo {
                Button("Exit demo") {
                    mixer.disconnect()
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.demoText)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(Theme.demo.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.demo.opacity(0.55), lineWidth: 1))
                .buttonStyle(.plain)
            } else {
                IconButton(systemName: "power", accessibilityLabel: L("Disconnect from mixer")) {
                    mixer.disconnect()
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: isShort ? 52 : 64)
        .background(Theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }
}

/// The page for a `Screen`.
struct PresentedScreenView: View {
    @Environment(Mixer.self) private var mixer
    let screen: Screen

    var body: some View {
        switch screen {
        case .channel(let kind):
            if let strip = mixer.strip(kind) {
                ChannelDetailView(strip: strip)
            }
        case .serviceMode:
            ServiceModeView()
        case .serviceEditor:
            ServiceEditorView()
        case .monitorPairing:
            MonitorPairingView()
        case .backups:
            BackupView()
        case .snapshots:
            SnapshotsView()
        case .muteGroups:
            MuteGroupsView()
        case .settings:
            SettingsHubView()
        }
    }
}

/// Always-visible "Settings" button: opens the page that lists everything that isn't a fader.
struct MoreMenu: View {
    @Environment(Mixer.self) private var mixer
    var showsTitle = true

    var body: some View {
        Button {
            mixer.presentedScreen = .settings
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .semibold))
                if showsTitle {
                    Text("Settings")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .foregroundStyle(Theme.textControl)
            .padding(.horizontal, showsTitle ? 14 : 0)
            .frame(minWidth: 44, minHeight: 44)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
        .accessibilityHint("Order of service, mute groups, backups, snapshots, pairing, language")
    }
}

struct ConnectionPill: View {
    @Environment(Mixer.self) private var mixer

    var body: some View {
        let (label, color, text): (String, Color, Color) = {
            if mixer.isDemo { return (L("Demo mixer"), Theme.demo, Theme.demoText) }
            if mixer.status == .connected {
                return (mixer.latency.map { L("Connected · \($0) ms") } ?? L("Connected"), Theme.meterGreen, Theme.greenText)
            }
            return (L("Reconnecting…"), Theme.accent, Theme.accentText)
        }()
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(text)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(color.opacity(0.13), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.45), lineWidth: 1))
        .fixedSize()
    }
}

struct UndoButton: View {
    @Environment(Mixer.self) private var mixer

    var body: some View {
        let count = mixer.history.count
        Menu {
            Section("Recent changes") {
                ForEach(mixer.history.suffix(8).reversed()) { change in
                    Text("\(change.date.hollyMixer(date: .omitted, time: .shortened)) · \(change.label)")
                }
            }
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(count > 0 ? Theme.textBright : Theme.textDim)
                .frame(width: 44, height: 44)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    // A dot says "something was changed and can be undone"; the list shows how much.
                    if count > 0 {
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Theme.background, lineWidth: 2))
                            .offset(x: 3, y: -3)
                    }
                }
        } primaryAction: {
            mixer.undo()
        }
        .disabled(count == 0)
        .accessibilityLabel("Undo. \(count) changes in history")
    }
}

struct MiniStereoMeter: View {
    let left: Float
    let right: Float

    var body: some View {
        VStack(spacing: 5) {
            row("L", left)
            row("R", right)
        }
        .accessibilityElement()
        .accessibilityLabel("Main LR level")
    }

    private func row(_ label: String, _ level: Float) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 8)
            GeometryReader { geometry in
                let fraction = CGFloat(min(max((level + 60) / 60, 0), 1))
                ZStack(alignment: .trailing) {
                    LinearGradient(stops: [
                        .init(color: Theme.meterGreen, location: 0), .init(color: Theme.meterGreen, location: 0.7),
                        .init(color: Theme.meterAmber, location: 0.7), .init(color: Theme.meterAmber, location: 0.9),
                        .init(color: Theme.meterRed, location: 0.9), .init(color: Theme.meterRed, location: 1),
                    ], startPoint: .leading, endPoint: .trailing)
                    Color(hex: 0x121318, opacity: 0.86)
                        .frame(width: geometry.size.width * (1 - fraction))
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 5)
        }
    }
}

struct IconButton: View {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textControl)
                .frame(width: 44, height: 44)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// The Holly Mixer mark: three fader tracks with orange caps.
struct HollyMixerLogo: View {
    var size: CGFloat = 20

    var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 20
            for x in [4.0, 10.0, 16.0] {
                var line = Path()
                line.move(to: CGPoint(x: x * scale, y: 2 * scale))
                line.addLine(to: CGPoint(x: x * scale, y: 18 * scale))
                context.stroke(line, with: .color(Color(hex: 0x4A4F58)),
                               style: StrokeStyle(lineWidth: 1.6 * scale, lineCap: .round))
            }
            for (x, y) in [(1.5, 10.0), (7.5, 4.5), (13.5, 8.0)] {
                let rect = CGRect(x: x * scale, y: y * scale, width: 5 * scale, height: 3 * scale)
                context.fill(Path(roundedRect: rect, cornerRadius: scale), with: .color(Theme.accent))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Holly Mixer")
    }
}

// MARK: - Mix selector and banners

/// Chips for Main LR, Bus 1-6 and FX 1-4; the selected mix decides what the faders control.
struct MixSelector: View {
    @Environment(Mixer.self) private var mixer
    var isCompact = false

    private let targets: [MixTarget] = [.main]
        + (1...6).map { MixTarget.bus($0) }
        + (1...4).map { MixTarget.fxSend($0) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("MIX")
                    .sectionLabelStyle()
                    .padding(.trailing, 2)
                ForEach(targets, id: \.self) { target in
                    chip(for: target)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: isCompact ? 42 : 56)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
    }

    private func chip(for target: MixTarget) -> some View {
        let strip = mixer.master(for: target)
        let isSelected = mixer.selectedMix == target
        let selectedColor = target == .main ? Theme.accent : strip.color
        return Button {
            mixer.selectedMix = target
        } label: {
            HStack(spacing: 7) {
                if target != .main {
                    Circle().fill(strip.color).frame(width: 8, height: 8)
                    Text(strip.shortLabel)
                        .font(Theme.mono(11, .regular))
                        .foregroundStyle(Theme.textTertiary)
                }
                Text(strip.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : Color(hex: 0xD5D8DD))
                    .lineLimit(1)
            }
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .frame(height: isCompact ? 32 : 40)
            .background(isSelected ? selectedColor.opacity(target == .main ? 0.16 : 0.24) : Theme.strip,
                        in: Capsule())
            .overlay(Capsule().stroke(isSelected ? selectedColor : Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(strip.displayName) mix")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct SendsBanner: View {
    @Environment(Mixer.self) private var mixer
    let master: Strip

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "headphones")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(master.color)
            (Text("Faders are sends to ") + Text(master.displayName).foregroundColor(master.color))
                .font(.system(size: 15, weight: .semibold))
            Text(L("\(master.shortLabel.replacingOccurrences(of: "B", with: L("Bus "))) · sends on faders"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer()
            Button("Back to Main") {
                mixer.selectedMix = .main
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(master.onColor)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(master.color, in: RoundedRectangle(cornerRadius: 9))
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(master.color.opacity(0.16))
        .overlay(alignment: .bottom) {
            Rectangle().fill(master.color.opacity(0.5)).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

struct ReconnectingBanner: View {
    @Environment(Mixer.self) private var mixer

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accentText)
            Text("Lost the mixer · retrying")
                .font(.system(size: 15, weight: .semibold))
            Text("Controls are read-only until it answers.")
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: 0xF5C59A))
                .lineLimit(1)
            Spacer()
            Button("Retry now") {
                mixer.retryNow()
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 9))
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Theme.accent.opacity(0.16))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.accent.opacity(0.6)).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Footer

/// Bottom bar: the four mute groups. Assign channels to them in Settings > Mute groups.
struct MixerFooter: View {
    @Environment(Mixer.self) private var mixer
    var isShort = false

    var body: some View {
        HStack(spacing: 14) {
            Text("MUTE GROUPS").sectionLabelStyle()
            HStack(spacing: 8) {
                ForEach(1...4, id: \.self) { number in
                    let isOn = mixer.muteGroups[number - 1]
                    Button {
                        mixer.toggleMuteGroup(number)
                    } label: {
                        Text("\(number)")
                            .font(Theme.mono(15, .bold))
                            .foregroundStyle(isOn ? .white : Theme.textSecondary)
                            .frame(width: 72, height: isShort ? 34 : 44)
                            .background(isOn ? Theme.mute : Theme.card, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(isOn ? Theme.muteBorder : Color.white.opacity(0.08), lineWidth: 1))
                            .shadow(color: isOn ? Theme.mute.opacity(0.45) : .clear, radius: 9)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Mute group \(number)"))
                    .accessibilityValue(isOn ? "on" : "off")
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: isShort ? 46 : 68)
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }
}
