import SwiftUI

/// The sections of the detail page.
enum ChannelDetailTab: String, CaseIterable, Identifiable {
    case input = "Input"
    case gate = "Gate"
    case eq = "EQ"
    case dynamics = "Dynamics"
    case sends = "Sends"
    case config = "Config"

    var id: String { rawValue }

    /// Tabs a strip has: channels all of them, returns EQ and sends, buses and main EQ and dynamics.
    /// A Soundcraft Ui has no gate, EQ or dynamics the app can drive yet.
    @MainActor
    static func available(for strip: Strip, soundcraft: Bool = false) -> [ChannelDetailTab] {
        allCases.filter { tab in
            switch tab {
            case .input: return strip.hasPreamp
            case .gate: return strip.hasGate && !soundcraft
            case .eq: return strip.hasEQ && !soundcraft
            case .dynamics: return strip.hasDynamics && !soundcraft
            case .sends: return strip.hasSendLevels
            case .config: return true
            }
        }
    }
}

/// Channel / bus / main detail page (Channel.dc.html): preamp, gate, EQ, dynamics, sends and config.
@MainActor
struct ChannelDetailView: View {
    @Environment(Mixer.self) private var mixer
    @Environment(\.horizontalSizeClass) private var sizeClass
    let strip: Strip

    @State private var selectedTab: ChannelDetailTab = {
        #if DEBUG
        if let raw = ScreenshotMode.tab, let tab = ChannelDetailTab(rawValue: raw) { return tab }
        #endif
        return .eq
    }()

    var body: some View {
        let tabs = ChannelDetailTab.available(for: strip, soundcraft: mixer.isSoundcraft)
        let current = tabs.contains(selectedTab) ? selectedTab : (tabs.contains(.eq) ? .eq : .config)
        VStack(spacing: 0) {
            ScreenTopBar(title: strip.displayName, subtitle: subtitle) {
                headerTrailing
            }
            tabBar(tabs: tabs, current: current)
            HStack(alignment: .top, spacing: 16) {
                content(current)
                    .id(strip.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                if sizeClass != .compact {
                    ChannelDetailSideFader(strip: strip)
                        .frame(width: 208)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, sizeClass == .compact ? 8 : 16)
            if sizeClass == .compact {
                CompactRideBar(strip: strip)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .task(id: strip.id) {
            mixer.request(XR18Params.detailAddresses(for: strip))
        }
    }

    private var subtitle: String {
        switch strip.kind {
        case .channel(let number): return L("Input \(number)")
        case .auxIn: return L("Aux input")
        case .fxReturn(let number): return L("FX return \(number)")
        case .bus(let number): return L("Bus \(number) · 6-band EQ")
        case .fxSend(let number): return L("FX send \(number)")
        case .main: return L("Main LR · 6-band EQ")
        }
    }

    @ViewBuilder
    private func content(_ tab: ChannelDetailTab) -> some View {
        switch tab {
        case .input: ChannelDetailInputTab(strip: strip)
        case .gate: ChannelDetailGateTab(strip: strip)
        case .eq: ChannelDetailEQTab(strip: strip)
        case .dynamics: ChannelDetailDynamicsTab(strip: strip)
        case .sends: ChannelDetailSendsTab(strip: strip)
        case .config: ChannelDetailConfigTab(strip: strip)
        }
    }

    // MARK: Top bar

    private var headerTrailing: some View {
        HStack(spacing: 8) {
            if strip.hasPreamp && sizeClass != .compact {
                neighbourButton(offset: -1)
                neighbourButton(offset: 1)
                statusChips
            }
            Button {
                mixer.undo()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward")
                    if sizeClass != .compact { Text("Undo") }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textBright)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(mixer.history.isEmpty)
            .opacity(mixer.history.isEmpty ? 0.4 : 1)
            .accessibilityLabel("Undo")
            if sizeClass != .compact {
                Button {
                    mixer.presentedScreen = nil
                } label: {
                    Text("Done")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Previous / next input channel.
    private func neighbourButton(offset: Int) -> some View {
        let number = strip.channelNumber ?? 1
        let target = number + offset
        let exists = (1...16).contains(target)
        let neighbour = exists ? mixer.channels[target - 1] : nil
        return Button {
            if exists {
                mixer.selectedStrip = .channel(target)
                mixer.presentedScreen = .channel(.channel(target))
            }
        } label: {
            Image(systemName: offset < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.textControl)
                .frame(width: 44, height: 44)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!exists)
        .opacity(exists ? 1 : 0.35)
        .accessibilityLabel(offset < 0 ? L("Previous channel") : L("Next channel"))
        .accessibilityValue(neighbour?.displayName ?? "")
    }

    private var statusChips: some View {
        let number = strip.channelNumber ?? 1
        let phantom = mixer.param(XR18Params.headamp(number, "phantom")).bool ?? false
        let gain = mixer.realValue(XR18Params.headamp(number, "gain"), XR18Params.preampGain)
        let lowCutOn = EQModel.lowCutIsOn(mixer, strip)
        let lowCut = lowCutOn ? L("LC \(ParamFormat.frequency(EQModel.lowCutFrequency(mixer, strip))) Hz") : L("LC off")
        return HStack(spacing: 6) {
            chip(phantom ? L("+48V on") : L("+48V off"), color: phantom ? Theme.meterRed : Theme.textTertiary)
            chip(gain.map { L("Gain \(ParamFormat.signed($0))") } ?? L("Gain —"), color: Theme.textControl)
            chip(lowCut, color: lowCutOn ? Theme.textBright : Theme.textTertiary)
        }
        .padding(.trailing, 4)
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Theme.mono(12, .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    // MARK: Tabs

    private func tabBar(tabs: [ChannelDetailTab], current: ChannelDetailTab) -> some View {
        let buttons = HStack(spacing: 2) {
            ForEach(tabs) { tab in
                tabButton(tab, isCurrent: tab == current)
            }
        }
        .padding(3)
        .background(Theme.strip, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
        .padding(.horizontal, 16)
        return Group {
            if sizeClass == .compact {
                // Every tab fits on a phone: no hidden Sends or Config behind a scroll.
                buttons.frame(height: 56)
            } else {
                ScrollView(.horizontal, showsIndicators: false) { buttons }
                    .frame(height: 64)
            }
        }
    }

    private func tabButton(_ tab: ChannelDetailTab, isCurrent: Bool) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: sizeClass == .compact ? 3 : 8) {
                Text(LocalizedStringKey(tab.rawValue))
                    .font(.system(size: sizeClass == .compact ? 12 : 14, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if isActive(tab) {
                    Circle().fill(Theme.meterGreen).frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(isCurrent ? Color.white : Theme.textSecondary)
            .padding(.horizontal, sizeClass == .compact ? 2 : 20)
            .frame(maxWidth: sizeClass == .compact ? .infinity : nil)
            .frame(height: 44)
            .background(isCurrent ? Theme.controlSelected : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(isCurrent ? Theme.accent.opacity(0.7) : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(tab.rawValue)))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    /// Green dot on a tab whose section is switched on.
    private func isActive(_ tab: ChannelDetailTab) -> Bool {
        switch tab {
        case .gate: return mixer.param(XR18Params.gate(strip.base, "on")).bool ?? strip.gateOn
        case .eq: return EQModel.isOn(mixer, strip)
        case .dynamics: return mixer.param(XR18Params.dyn(strip.base, "on")).bool ?? strip.compressorOn
        default: return false
        }
    }
}

/// The strip's fader, meter, solo and mute, always at hand while editing (right column).
@MainActor
private struct ChannelDetailSideFader: View {
    @Environment(Mixer.self) private var mixer
    let strip: Strip

    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 10) {
            Text("RIDE WHILE EDITING").sectionLabelStyle()
                .frame(maxWidth: .infinity, alignment: .leading)
            if strip.hasGate || strip.hasDynamics {
                HStack(spacing: 6) {
                    if strip.hasGate {
                        Pill(text: L("GATE"), isOn: mixer.param(XR18Params.gate(strip.base, "on")).bool ?? strip.gateOn,
                             onColor: Theme.meterGreen, onText: Theme.greenText)
                    }
                    if strip.hasDynamics {
                        Pill(text: L("DYN"), isOn: mixer.param(XR18Params.dyn(strip.base, "on")).bool ?? strip.compressorOn,
                             onColor: Theme.meterAmber, onText: Theme.amberText)
                    }
                }
            }
            HStack(spacing: 6) {
                FaderView(
                    value: strip.fader,
                    lineColor: strip.color,
                    capLineColor: strip.color,
                    isMuted: !strip.isOn,
                    capWidth: 44,
                    label: L("\(strip.displayName) fader"),
                    isDragging: $isDragging,
                    onTouchingChanged: { mixer.setTouching(strip, .fader, $0) },
                    onChange: { mixer.setLevel(strip, .fader, to: $0) }
                )
                MeterView(level: strip.meter, peak: strip.peak)
                    .frame(width: 10)
                    .padding(.vertical, 28)
            }
            Text(formatDecibels(strip.fader) + L(" dB"))
                .font(Theme.mono(14, .bold))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
            if strip.soloAddress != nil {
                StripButton(title: L("SOLO"), isOn: strip.isSoloed, style: .solo, height: 44,
                            accessibilityLabel: L("Solo \(strip.displayName)")) {
                    mixer.toggleSolo(strip)
                }
            }
            StripButton(title: L("MUTE"), isOn: !strip.isOn, style: .mute, height: 56,
                        accessibilityLabel: L("Mute \(strip.displayName)")) {
                mixer.toggleMute(strip)
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border, lineWidth: 1))
    }
}


/// iPhone: the channel's fader, MUTE, SOLO and previous/next, pinned under the editing pages.
@MainActor
private struct CompactRideBar: View {
    @Environment(Mixer.self) private var mixer
    let strip: Strip

    var body: some View {
        HStack(spacing: 8) {
            if let number = strip.channelNumber {
                step(number - 1, symbol: "chevron.left", label: L("Previous channel"))
                step(number + 1, symbol: "chevron.right", label: L("Next channel"))
            }
            PhoneToggleButton(title: "M", isOn: !strip.isOn, style: .mute, silencedBy: strip.isOn ? mixer.silencedBy(strip) : nil,
                              accessibilityLabel: L("Mute \(strip.displayName)")) {
                mixer.toggleMute(strip)
            }
            if strip.soloAddress != nil {
                PhoneToggleButton(title: "S", isOn: strip.isSoloed, style: .solo,
                                  accessibilityLabel: L("Solo \(strip.displayName)")) {
                    mixer.toggleSolo(strip)
                }
            }
            VStack(spacing: 0) {
                Text(formatDecibels(strip.fader) + L(" dB"))
                    .font(Theme.mono(12, .bold))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                PhoneHorizontalFader(
                    value: strip.fader, lineColor: strip.color, isMuted: !strip.isOn, meterStrip: strip,
                    label: L("\(strip.displayName) fader"),
                    onTouchingChanged: { mixer.setTouching(strip, .fader, $0) },
                    onChange: { mixer.setLevel(strip, .fader, to: $0) }
                )
                .frame(height: 30)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func step(_ target: Int, symbol: String, label: String) -> some View {
        let exists = (1...16).contains(target)
        return Button {
            if exists {
                mixer.selectedStrip = .channel(target)
                mixer.presentedScreen = .channel(.channel(target))
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.textControl)
                .frame(width: 36, height: 44)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!exists)
        .opacity(exists ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}
