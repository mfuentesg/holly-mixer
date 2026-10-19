import SwiftUI

struct MixerView: View {
    @Environment(Mixer.self) private var mixer
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var bank = Bank.channels1to8

    var body: some View {
        let target = mixer.selectedMix
        let master = mixer.master(for: target)
        let control = target.control
        let busColor: Color? = target == .main ? nil : master.color
        let isReconnecting = mixer.status != .connected && !mixer.isDemo

        VStack(spacing: 0) {
            MixerHeader(isCompact: sizeClass == .compact)
            MixSelector()
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
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(mixer.inputs.filter { $0.hasControl(control) }) { strip in
                                ChannelStripView(strip: strip, control: control, busColor: busColor)
                            }
                            if target == .main {
                                ForEach(mixer.buses + mixer.fxSends) { strip in
                                    ChannelStripView(strip: strip, control: .fader, busColor: nil)
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
                    .onChange(of: bank) { _, newBank in
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(newBank.firstStrip, anchor: .leading)
                        }
                    }
                }
                ChannelStripView(strip: master, control: .fader, busColor: busColor, isMaster: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .opacity(isReconnecting ? 0.4 : 1)
            .saturation(isReconnecting ? 0.35 : 1)
            .allowsHitTesting(!isReconnecting)

            MixerFooter(bank: $bank, isCompact: sizeClass == .compact)
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
        .onChange(of: target) { _, newTarget in
            if newTarget != .main && bank == .masters { bank = .channels1to8 }
        }
    }
}

enum Bank: String, CaseIterable, Identifiable {
    case channels1to8 = "1–8"
    case channels9to16 = "9–16"
    case auxFX = "Aux · FX"
    case masters = "Buses · FX Sends"

    var id: String { rawValue }

    var firstStrip: Strip.Kind {
        switch self {
        case .channels1to8: return .channel(1)
        case .channels9to16: return .channel(9)
        case .auxFX: return .auxIn
        case .masters: return .bus(1)
        }
    }
}

// MARK: - Header

struct MixerHeader: View {
    @Environment(Mixer.self) private var mixer
    let isCompact: Bool

    var body: some View {
        HStack(spacing: 12) {
            MixitLogo(size: 20)
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

            if !isCompact {
                HeaderSceneControl()
                Spacer(minLength: 8)
            }

            if !isCompact {
                HStack(spacing: 4) {
                    ForEach(1...4, id: \.self) { number in
                        let isOn = mixer.muteGroups[number - 1]
                        Button {
                            mixer.toggleMuteGroup(number)
                        } label: {
                            Text("MG\(number)")
                                .font(Theme.mono(11, .bold))
                                .foregroundStyle(isOn ? .white : Theme.textSecondary)
                                .frame(width: 44, height: 44)
                                .background(isOn ? Theme.mute : Theme.card, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .stroke(isOn ? Theme.muteBorder : Color.white.opacity(0.08), lineWidth: 1))
                                .shadow(color: isOn ? Theme.mute.opacity(0.45) : .clear, radius: 9)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Mute group \(number)")
                        .accessibilityValue(isOn ? "on" : "off")
                    }
                }
                Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 28)
            }

            UndoButton()
            MoreMenu()

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
        .frame(height: 64)
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
        case .scenes:
            ScenesView()
        case .serviceMode:
            ServiceModeView()
        case .serviceEditor:
            ServiceEditorView()
        case .monitorPairing:
            MonitorPairingView()
        case .backups:
            BackupView()
        }
    }
}

/// Header menu for the less frequent pages.
struct MoreMenu: View {
    @Environment(Mixer.self) private var mixer
    @Environment(Localization.self) private var localization

    var body: some View {
        Menu {
            Button {
                mixer.presentedScreen = .scenes
            } label: {
                Label("Order of service", systemImage: "list.bullet.rectangle")
            }
            Button {
                mixer.presentedScreen = .serviceMode
            } label: {
                Label("Start Service Mode", systemImage: "lock")
            }
            Button {
                mixer.presentedScreen = .serviceEditor
            } label: {
                Label("Edit Service Mode", systemImage: "slider.horizontal.3")
            }
            Button {
                mixer.presentedScreen = .monitorPairing
            } label: {
                Label("Pair a musician's iPhone", systemImage: "qrcode")
            }
            Button {
                mixer.presentedScreen = .backups
            } label: {
                Label("Settings backup", systemImage: "clock.arrow.circlepath")
            }
            Picker("Language", selection: Bindable(localization).language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textControl)
                .frame(width: 44, height: 44)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .accessibilityLabel("More")
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
                    Text("\(change.date.mixit(date: .omitted, time: .shortened)) · \(change.label)")
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
                    if count > 0 {
                        Text("\(count)")
                            .font(Theme.mono(10, .heavy))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Theme.accent, in: Capsule())
                            .offset(x: 5, y: -5)
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

/// The Mixit mark: three fader tracks with orange caps.
struct MixitLogo: View {
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
        .accessibilityLabel("Mixit")
    }
}

// MARK: - Mix selector and banners

/// Chips for Main LR, Bus 1-6 and FX 1-4; the selected mix decides what the faders control.
struct MixSelector: View {
    @Environment(Mixer.self) private var mixer

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
        .frame(height: 56)
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
            .frame(height: 40)
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

struct MixerFooter: View {
    @Environment(Mixer.self) private var mixer
    @Binding var bank: Bank
    let isCompact: Bool

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(Bank.allCases.filter { $0 != .masters || mixer.selectedMix == .main }) { item in
                    let isSelected = bank == item
                    Button {
                        bank = item
                    } label: {
                        Text(LocalizedStringKey(item.rawValue))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isSelected ? .white : Theme.textSecondary)
                            .lineLimit(1)
                            .padding(.horizontal, isCompact ? 10 : 18)
                            .frame(height: 44)
                            .background(isSelected ? Theme.controlSelected : .clear, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9)
                                .stroke(isSelected ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))

            Spacer()

            if !isCompact {
                Text("QUICK").sectionLabelStyle()
                quickMute(mixer.channels[0])
                if mixer.selectedMix == .main {
                    quickMix(mixer.buses[1], target: .bus(2))
                } else {
                    quickBackToMain
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 68)
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    private func quickMute(_ strip: Strip) -> some View {
        let muted = !strip.isOn
        return Button {
            mixer.toggleMute(strip)
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(strip.color).frame(width: 10, height: 10)
                Text(muted ? L("Unmute \(strip.displayName)") : L("Mute \(strip.displayName)"))
            }
            .quickButtonStyle(fill: muted ? Theme.mute.opacity(0.25) : Theme.card,
                              border: Theme.mute.opacity(muted ? 0.9 : 0.55))
        }
        .buttonStyle(.plain)
    }

    private func quickMix(_ strip: Strip, target: MixTarget) -> some View {
        Button {
            mixer.selectedMix = target
        } label: {
            HStack(spacing: 8) {
                Circle().fill(strip.color).frame(width: 8, height: 8)
                Text(strip.displayName)
            }
            .quickButtonStyle(fill: Theme.card, border: Color.white.opacity(0.1))
        }
        .buttonStyle(.plain)
    }

    private var quickBackToMain: some View {
        Button {
            mixer.selectedMix = .main
        } label: {
            HStack(spacing: 8) {
                Circle().fill(Theme.accent).frame(width: 8, height: 8)
                Text("Back to Main")
            }
            .quickButtonStyle(fill: Theme.card, border: Theme.accent.opacity(0.6))
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    func quickButtonStyle(fill: Color, border: Color) -> some View {
        font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(fill, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(border, lineWidth: 1))
    }
}
