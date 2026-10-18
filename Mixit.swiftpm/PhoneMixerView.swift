import SwiftUI

/// Groups of strips shown at once on the iPhone mixer (bottom bar of the design).
enum PhoneBank: CaseIterable, Hashable {
    case first, second, fx, buses

    func title(isMain: Bool) -> String {
        switch self {
        case .first: return "1–9"
        case .second: return "10–16"
        case .fx: return "FX"
        case .buses: return isMain ? "Buses" : "Master"
        }
    }

    /// Strips in this bank for the selected mix.
    @MainActor
    func strips(in mixer: Mixer) -> [Strip] {
        let target = mixer.selectedMix
        let control = target.control
        switch self {
        case .first: return Array(mixer.channels.prefix(9)).filter { $0.hasControl(control) }
        case .second: return Array(mixer.channels.dropFirst(9)).filter { $0.hasControl(control) }
        case .fx: return ([mixer.auxIn] + mixer.fxReturns).filter { $0.hasControl(control) }
        case .buses: return target == .main ? mixer.buses + mixer.fxSends : [mixer.master(for: target)]
        }
    }
}

/// iPhone mixer in portrait: a list of horizontal faders for the selected mix.
struct PhoneMixerView: View {
    @Environment(Mixer.self) private var mixer
    @State private var bank = PhoneBank.first
    @State private var showScanner = false
    var onPair: (MonitorPairing) -> Void

    var body: some View {
        let target = mixer.selectedMix
        let master = mixer.master(for: target)
        let busColor: Color? = target == .main ? nil : master.color
        let isReconnecting = mixer.status != .connected && !mixer.isDemo

        VStack(spacing: 0) {
            header(master: master, busColor: busColor)
            if isReconnecting {
                Text("Reconnecting to the mixer…")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accentText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .background(Theme.accent.opacity(0.13))
            }
            rows(target: target, busColor: busColor)
                .opacity(isReconnecting ? 0.4 : 1)
                .saturation(isReconnecting ? 0.35 : 1)
                .allowsHitTesting(!isReconnecting)
            bankBar(isMain: target == .main)
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.textPrimary)
        .fullScreenCover(item: Bindable(mixer).presentedScreen) { screen in
            PresentedScreenView(screen: screen)
        }
        .sheet(isPresented: $showScanner) {
            MonitorPairingScannerSheet { pairing in
                showScanner = false
                onPair(pairing)
            }
        }
    }

    // MARK: - Header

    private func header(master: Strip, busColor: Color?) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                ConnectionPill()
                mixMenu(master: master, busColor: busColor)
            }
            Spacer(minLength: 0)
            UndoButton()
            IconButton(systemName: "rectangle.split.1x2", accessibilityLabel: "Scenes") {
                mixer.presentedScreen = .scenes
            }
            moreMenu
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func mixMenu(master: Strip, busColor: Color?) -> some View {
        Menu {
            Picker("Mix", selection: Bindable(mixer).selectedMix) {
                Text("Main LR").tag(MixTarget.main)
                ForEach(1...6, id: \.self) { number in
                    Text(mixer.master(for: .bus(number)).displayName).tag(MixTarget.bus(number))
                }
                ForEach(1...4, id: \.self) { number in
                    Text(mixer.master(for: .fxSend(number)).displayName).tag(MixTarget.fxSend(number))
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                if let busColor {
                    Circle().fill(busColor).frame(width: 10, height: 10)
                }
                Text(master.displayName)
                    .font(.system(size: 24, weight: .bold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(Theme.accentText)
            }
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Mix: \(master.displayName)")
        .accessibilityHint("Choose which mix the faders control")
    }

    private var moreMenu: some View {
        Menu {
            Button {
                showScanner = true
            } label: {
                Label("Pair as musician…", systemImage: "qrcode.viewfinder")
            }
            Button {
                mixer.presentedScreen = .serviceMode
            } label: {
                Label("Start Service Mode", systemImage: "lock")
            }
            Button {
                mixer.disconnect()
            } label: {
                Label("Disconnect", systemImage: "wifi.slash")
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

    // MARK: - Rows

    private func rows(target: MixTarget, busColor: Color?) -> some View {
        let strips = bank.strips(in: mixer)
        return ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(strips) { strip in
                    PhoneChannelRow(strip: strip, busColor: busColor,
                                    control: strip.sends.isEmpty ? .fader : target.control)
                }
                if strips.isEmpty {
                    Text("No faders in this bank for this mix.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.top, 40)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private func bankBar(isMain: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(PhoneBank.allCases, id: \.self) { item in
                bankButton(item, isMain: isMain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Theme.background)
    }

    private func bankButton(_ item: PhoneBank, isMain: Bool) -> some View {
        let isSelected = item == bank
        return Button {
            bank = item
        } label: {
            Text(item.title(isMain: isMain))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(isSelected ? Theme.controlSelected : Theme.strip, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Theme.accent.opacity(0.7) : Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One strip as a row: mute, solo, name and level, and a horizontal fader.
struct PhoneChannelRow: View {
    @Environment(Mixer.self) private var mixer
    let strip: Strip
    var busColor: Color?
    let control: LevelControl

    var body: some View {
        let isMuted = !strip.isOn
        let isSelected = mixer.selectedStrip == strip.kind
        let level = strip.level(control)

        HStack(spacing: 8) {
            buttons(isMuted: isMuted)
            VStack(spacing: 2) {
                titleLine(isMuted: isMuted, level: level)
                PhoneHorizontalFader(
                    value: level, lineColor: busColor ?? strip.color, isMuted: isMuted, meterStrip: strip,
                    label: "\(strip.displayName) \(control == .fader ? "fader" : "send")",
                    onTouchingChanged: { mixer.setTouching(strip, control, $0) },
                    onChange: { mixer.setLevel(strip, control, to: $0) }
                )
                .frame(height: 36)
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .frame(height: 64)
        .background(isSelected ? Theme.accent.opacity(0.08) : Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Theme.accent.opacity(0.5) : Color.white.opacity(0.05), lineWidth: 1)
        }
        .opacity(strip.isNamed ? 1 : 0.7)
    }

    private func buttons(isMuted: Bool) -> some View {
        HStack(spacing: 8) {
            PhoneToggleButton(title: "M", isOn: isMuted, style: .mute,
                              accessibilityLabel: "Mute \(strip.displayName), \(isMuted ? "on" : "off")") {
                mixer.toggleMute(strip)
            }
            if strip.soloAddress != nil {
                PhoneToggleButton(title: "S", isOn: strip.isSoloed, style: .solo,
                                  accessibilityLabel: "Solo \(strip.displayName), \(strip.isSoloed ? "on" : "off")") {
                    mixer.toggleSolo(strip)
                }
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
    }

    /// Colour bar, number, name and dB readout. Tap or swipe left to open the channel page.
    private func titleLine(isMuted: Bool, level: Float) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(strip.color.opacity(isMuted ? 0.4 : 1))
                .frame(width: 4, height: 14)
            Text(strip.shortLabel)
                .font(Theme.mono(11, .regular))
                .foregroundStyle(Theme.textTertiary)
            Text(strip.displayName)
                .font(Theme.rounded(15))
                .foregroundStyle(isMuted ? Theme.textMuted : Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(formatDecibels(level))
                .font(Theme.mono(13, .bold))
                .foregroundStyle(isMuted ? Theme.textMuted : Theme.textBright)
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        .onTapGesture(perform: openChannel)
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { gesture in
                    let isHorizontal = abs(gesture.translation.width) > abs(gesture.translation.height) * 2
                    if isHorizontal, gesture.translation.width < -40 { openChannel() }
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(strip.displayName), open channel page")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, openChannel)
    }

    private func openChannel() {
        mixer.selectedStrip = strip.kind
        mixer.presentedScreen = .channel(strip.kind)
    }
}

/// 44 pt mute or solo button.
struct PhoneToggleButton: View {
    enum Style { case mute, solo }

    let title: String
    let isOn: Bool
    let style: Style
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(foreground)
                .frame(width: 44, height: 44)
                .background(background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(border, lineWidth: 1))
                .shadow(color: isOn && style == .mute ? Theme.mute.opacity(0.45) : .clear, radius: 7)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var foreground: Color {
        guard isOn else { return Theme.textSecondary }
        return style == .mute ? .white : Theme.onSolo
    }

    private var background: Color {
        guard isOn else { return Theme.control }
        return style == .mute ? Theme.mute : Theme.solo
    }

    private var border: Color {
        guard isOn else { return Color.white.opacity(0.08) }
        return style == .mute ? Theme.muteBorder : Theme.solo
    }
}
