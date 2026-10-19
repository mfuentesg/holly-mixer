import SwiftUI

/// Responsive grid of cards used by the Input, Sends and Config pages.
private struct CardGrid<Content: View>: View {
    var minimumWidth: CGFloat = 300
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumWidth), spacing: 16, alignment: .top)],
                      alignment: .leading, spacing: 16) {
                content()
            }
        }
    }
}

private struct CardTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased()).sectionLabelStyle()
    }
}

// MARK: - Input

/// Preamp page (channels only): gain, +48V, polarity and low cut.
@MainActor
struct ChannelDetailInputTab: View {
    @Environment(Mixer.self) private var mixer
    @Environment(\.horizontalSizeClass) private var sizeClass
    let strip: Strip

    @State private var confirmPhantom = false

    var body: some View {
        if let number = strip.channelNumber {
            CardGrid {
                gainCard(number)
                phantomCard(number)
                polarityCard
                lowCutCard
            }
        }
    }

    private func gainCard(_ number: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(text: L("Preamp gain"))
            HStack(alignment: .center, spacing: 24) {
                ParamKnob(address: XR18Params.headamp(number, "gain"), title: L("GAIN"),
                          range: XR18Params.preampGain, format: { ParamFormat.signed($0) + " dB" },
                          undoLabel: L("\(strip.displayName) gain"), tint: Theme.accent, bipolar: true,
                          dialSize: 110, width: 130)
                VStack(spacing: 6) {
                    MeterView(level: strip.meter, peak: strip.peak)
                        .frame(width: 12, height: 110)
                    Text("LEVEL").sectionLabelStyle()
                }
            }
            .frame(maxWidth: .infinity)
            if sizeClass == .compact {
                // Exact 1 dB steps next to the dial: no need to drag it on a phone.
                HStack(spacing: 12) {
                    gainStep(-1, number: number)
                    gainStep(1, number: number)
                }
            }
            Text("−12 to +60 dB. Drag the knob up or down.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
        .detailCard()
    }

    private func gainStep(_ delta: Float, number: Int) -> some View {
        let address = XR18Params.headamp(number, "gain")
        return Button {
            let range = XR18Params.preampGain
            guard let stored = mixer.param(address).float else { return }
            let next = min(max(range.value(stored) + delta, range.value(0)), range.value(1))
            mixer.beginEdit(address)
            mixer.setContinuous(address, range.normalized(next))
            mixer.endEdit(address, label: L("\(strip.displayName) gain") + " " + ParamFormat.signed(next) + " dB")
        } label: {
            Text(delta < 0 ? "−1 dB" : "+1 dB")
                .font(Theme.mono(14, .bold))
                .foregroundStyle(Theme.textBright)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(delta < 0 ? L("Lower gain 1 dB") : L("Raise gain 1 dB"))
    }

    private func phantomCard(_ number: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(text: L("Phantom power"))
            ParamSwitch(address: XR18Params.headamp(number, "phantom"), title: "+48V",
                        undoLabel: "\(strip.displayName) +48V", tint: Theme.meterRed,
                        confirmTurnOn: { confirmPhantom = true })
            Text("For condenser microphones. Mute the channel first: switching it can cause a loud pop.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
        .detailCard()
        .confirmationDialog("Turn on +48V for \(strip.displayName)?", isPresented: $confirmPhantom,
                            titleVisibility: .visible) {
            Button("Turn on +48V", role: .destructive) {
                mixer.set(XR18Params.headamp(number, "phantom"), .int(1),
                          label: L("\(strip.displayName) +48V on"))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Phantom power can damage ribbon microphones and some other sources.")
        }
    }

    private var polarityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(text: L("Polarity"))
            ParamSwitch(address: XR18Params.preamp(strip.base, "invert"), title: L("Invert (Ø)"),
                        undoLabel: L("\(strip.displayName) polarity"))
        }
        .detailCard()
    }

    private var lowCutCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(text: L("Low cut"))
            ParamSwitch(address: XR18Params.preamp(strip.base, "hpon"), title: L("Low cut"),
                        undoLabel: L("\(strip.displayName) low cut"))
            HStack {
                ParamKnob(address: XR18Params.preamp(strip.base, "hpf"), title: L("FREQ"),
                          range: XR18Params.lowCut, format: { ParamFormat.frequency($0) + " Hz" },
                          undoLabel: L("\(strip.displayName) low cut frequency"), tint: Theme.accent,
                          dialSize: 56, width: 90)
                Spacer()
                Text("20 to 400 Hz")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .detailCard()
    }
}

// MARK: - Sends

/// A horizontal slider for a strip level (its fader or one of its sends), same taper as the strip faders.
@MainActor
struct ChannelLevelSlider: View {
    @Environment(Mixer.self) private var mixer
    let strip: Strip
    let control: LevelControl
    var tint: Color = Theme.textControl
    var label = "Level"

    @State private var startLevel: Float?

    private let thumbWidth: CGFloat = 30

    var body: some View {
        let level = strip.level(control)
        GeometryReader { proxy in
            let travel = max(proxy.size.width - thumbWidth, 1)
            let thumbX = thumbWidth / 2 + travel * CGFloat(level)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.well).frame(height: 6)
                    .overlay(Capsule().stroke(Color.white.opacity(0.06), lineWidth: 1))
                Capsule().fill(tint.opacity(0.9)).frame(width: thumbX, height: 6)
                Rectangle()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: 1, height: 14)
                    .offset(x: thumbWidth / 2 + travel * CGFloat(FaderView.unity))
                thumb.offset(x: thumbX - thumbWidth / 2)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(drag(level: level, travel: travel, thumbX: thumbX))
            .simultaneousGesture(TapGesture(count: 2).onEnded { setOnce(FaderView.unity) })
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(formatDecibels(level) + " dB")
        .accessibilityAdjustableAction { direction in
            setOnce(min(max(level + (direction == .increment ? 0.02 : -0.02), 0), 1))
        }
    }

    private var thumb: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(LinearGradient(colors: [Color(hex: 0x464A52), Color(hex: 0x2B2E34)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: thumbWidth, height: 34)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.16), lineWidth: 1))
            .overlay(Rectangle().fill(tint).frame(width: 2, height: 18))
            .shadow(color: .black.opacity(0.5), radius: 5, y: 3)
    }

    private func drag(level: Float, travel: CGFloat, thumbX: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if startLevel == nil {
                    mixer.setTouching(strip, control, true)
                    // Relative drag, like the strip faders: touching the track never makes the level jump.
                    startLevel = level
                }
                let moved = Float(gesture.translation.width / travel)
                mixer.setLevel(strip, control, to: min(max((startLevel ?? level) + moved, 0), 1))
            }
            .onEnded { _ in
                startLevel = nil
                mixer.setTouching(strip, control, false)
            }
    }

    private func setOnce(_ value: Float) {
        mixer.setTouching(strip, control, true)
        mixer.setLevel(strip, control, to: value)
        mixer.setTouching(strip, control, false)
    }
}

/// Send levels of a strip to the 6 buses and 4 FX sends.
struct ChannelDetailSendsTab: View {
    let strip: Strip

    var body: some View {
        CardGrid(minimumWidth: 400) {
            ForEach(strip.sends.indices, id: \.self) { index in
                SendRow(strip: strip, index: index)
            }
        }
    }
}

private struct SendRow: View {
    @Environment(Mixer.self) private var mixer
    let strip: Strip
    let index: Int

    var body: some View {
        let target: MixTarget = index < 6 ? .bus(index + 1) : .fxSend(index - 5)
        let master = mixer.master(for: target)
        let level = strip.level(.send(index))
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(master.color)
                .frame(width: 6, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(master.displayName)
                    .font(Theme.rounded(15, .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(index < 6 ? L("Bus \(index + 1)") : L("FX send \(index - 5)"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(width: 118, alignment: .leading)
            ChannelLevelSlider(strip: strip, control: .send(index), tint: master.color,
                               label: L("Send to \(master.displayName)"))
            Text(formatDecibels(level))
                .font(Theme.mono(13, .bold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 48, alignment: .trailing)
        }
        .detailCard()
    }
}

// MARK: - Config

/// Name, colour, fader and mute.
@MainActor
struct ChannelDetailConfigTab: View {
    @Environment(Mixer.self) private var mixer
    @Environment(\.horizontalSizeClass) private var sizeClass
    let strip: Strip

    @State private var text = ""
    @FocusState private var isFocused: Bool

    private static let nameLimit = 12
    private static let colorNames = [L("Grey"), L("Red"), L("Green"), L("Yellow"), L("Blue"), L("Magenta"), L("Cyan"), L("White")]

    var body: some View {
        CardGrid(minimumWidth: 340) {
            nameCard
            colorCard
            dcaCard
            muteGroupCard
            // The side fader already shows level and MUTE on wide screens.
            if sizeClass == .compact { faderCard }
        }
        .onAppear { text = strip.name }
        .onChange(of: strip.name) { _, newName in
            if !isFocused { text = newName }
        }
    }

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(text: L("Name"))
            HStack {
                TextField("Name", text: $text)
                    .focused($isFocused)
                    .font(Theme.rounded(18, .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .submitLabel(.done)
                    .autocorrectionDisabled()
                    .onSubmit(commitName)
                    .onChange(of: text) { _, newText in
                        if newText.count > Self.nameLimit { text = String(newText.prefix(Self.nameLimit)) }
                    }
                    .onChange(of: isFocused) { _, focused in
                        if !focused { commitName() }
                    }
                Text("\(text.count)/\(Self.nameLimit)")
                    .font(Theme.mono(11, .regular))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(isFocused ? Theme.accent : Theme.border, lineWidth: 1))
        }
        .detailCard()
    }

    private func commitName() {
        let name = String(text.prefix(Self.nameLimit))
        guard name != strip.name else { return }
        mixer.set("\(strip.base)/config/name", .string(name),
                  label: L("\(strip.displayName) renamed \(name.isEmpty ? L("(no name)") : name)"))
    }

    private var colorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(text: L("Colour"))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 10)], spacing: 10) {
                ForEach(0..<8, id: \.self) { index in
                    swatch(index)
                }
            }
        }
        .detailCard()
    }

    private func swatch(_ index: Int) -> some View {
        let isSelected = strip.colorIndex % 8 == index
        return Button {
            mixer.set("\(strip.base)/config/color", .int(Int32(index)),
                      label: L("\(strip.displayName) colour \(Self.colorNames[index])"))
        } label: {
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.channelColors[index])
                .frame(height: 48)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .heavy))
                            .foregroundStyle(Theme.onChannelColors[index])
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.white : Color.white.opacity(0.1), lineWidth: isSelected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.colorNames[index])
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Which of the four DCA groups this strip belongs to.
    private var dcaCard: some View {
        let mask = mixer.dcaMask(of: strip)
        return VStack(alignment: .leading, spacing: 10) {
            CardTitle(text: L("DCA groups"))
            HStack(spacing: 8) {
                ForEach(mixer.dcas) { group in
                    let isMember = mask & (1 << (group.number - 1)) != 0
                    Button {
                        mixer.setDCAMembership(strip, dca: group.number, member: !isMember)
                    } label: {
                        VStack(spacing: 2) {
                            Text("DCA \(group.number)")
                                .font(Theme.mono(11, .bold))
                            Text(group.displayName)
                                .font(.system(size: 11))
                                .lineLimit(1)
                        }
                        .foregroundStyle(isMember ? Theme.onAccent : Theme.textBright)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(isMember ? group.color : Theme.control, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(isMember ? Color.clear : Theme.borderStrong, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("DCA \(group.number) \(group.displayName)")
                    .accessibilityValue(isMember ? L("yes") : L("no"))
                }
            }
            Text("Moving a DCA fader moves every channel in it, without changing their own faders.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
        .detailCard()
    }

    /// Which of the four mute groups this strip belongs to. The MUTE GROUPS buttons in the mixer's top bar
    /// silence every strip that is in the group.
    private var muteGroupCard: some View {
        let mask = mixer.muteGroupMask(of: strip)
        return VStack(alignment: .leading, spacing: 10) {
            CardTitle(text: L("Mute groups"))
            HStack(spacing: 8) {
                ForEach(1...4, id: \.self) { number in
                    let isMember = mask & (1 << (number - 1)) != 0
                    Button {
                        mixer.setMuteGroupMembership(strip, group: number, member: !isMember)
                    } label: {
                        Text(L("Group \(number)"))
                            .font(Theme.mono(12, .bold))
                            .foregroundStyle(isMember ? .white : Theme.textBright)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(isMember ? Theme.mute : Theme.control, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(isMember ? Theme.muteBorder : Theme.borderStrong, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Mute group \(number)"))
                    .accessibilityValue(isMember ? L("yes") : L("no"))
                }
            }
            Text("Pressing a mute group in the bottom bar silences every channel in it at once.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
        .detailCard()
    }

    private var faderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(text: L("Fader"))
            HStack(spacing: 12) {
                ChannelLevelSlider(strip: strip, control: .fader, tint: strip.color, label: L("\(strip.displayName) fader"))
                Text(formatDecibels(strip.fader) + L(" dB"))
                    .font(Theme.mono(14, .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 84, alignment: .trailing)
            }
            StripButton(title: L("MUTE"), isOn: !strip.isOn, style: .mute, height: 56,
                        accessibilityLabel: L("Mute \(strip.displayName)")) {
                mixer.toggleMute(strip)
            }
        }
        .detailCard()
    }
}
