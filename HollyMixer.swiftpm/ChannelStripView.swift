import SwiftUI

struct ChannelStripView: View {
    @Environment(Mixer.self) private var mixer
    let strip: Strip
    /// What the fader controls: the strip's own fader or one of its sends.
    let control: LevelControl
    /// Colour of the selected bus when the faders show sends.
    let busColor: Color?
    /// The wide strip pinned on the right: Main LR, or the selected bus.
    var isMaster = false

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var isDragging = false

    /// Landscape iPhone: drop the extras so the fader and both buttons fit.
    private var isCompact: Bool { verticalSizeClass == .compact }

    var body: some View {
        let level = strip.level(control)
        let isSendsMode: Bool = { if case .send = control { return true } else { return false } }()
        let silencer = isSendsMode ? nil : mixer.silencedBy(strip)
        let muted = isSendsMode ? mixer.isSendRemoved(strip, control) : !strip.isOn
        let isSelected = !isMaster && mixer.selectedStrip == strip.kind

        VStack(spacing: isCompact ? 4 : 6) {
            Rectangle()
                .fill(barColor)
                .opacity(muted ? 0.35 : strip.isNamed || isMaster ? 1 : 0.5)
                .frame(height: 4)
                .padding(.horizontal, isMaster ? -8 : -6)

            header(muted: muted || silencer != nil)

            if !isCompact {
                StripEQThumbnail(strip: strip, width: isMaster ? 96 : 66)
            }

            if strip.isChannel && !isCompact {
                processingPills
            }
            if strip.hasPan && !isMaster && !isCompact {
                PanArc(pan: strip.pan)
                    .frame(width: 66, height: 28)
            }
            if isMaster && !isCompact {
                Text(strip.meterRight == nil ? L("MONO") : L("STEREO"))
                    .sectionLabelStyle()
                    .frame(height: 28)
            }

            HStack(spacing: 3) {
                FaderView(
                    value: level,
                    lineColor: busColor ?? (strip.isNamed || isMaster ? strip.color : Theme.textDim),
                    capLineColor: busColor ?? (strip.isNamed || isMaster ? strip.color : Theme.textTertiary),
                    isMuted: muted || silencer != nil,
                    capWidth: isMaster ? 44 : strip.meterRight == nil ? 38 : 32,
                    label: faderLabel,
                    isCompact: isCompact,
                    isDragging: $isDragging,
                    onTouchingChanged: { mixer.setTouching(strip, control, $0) },
                    onChange: { mixer.setLevel(strip, control, to: $0) }
                )
                meters
                    .padding(.vertical, isCompact ? 20 : 28)
            }
            .frame(maxHeight: .infinity)

            Text(formatDecibels(level))
                .font(Theme.mono(12))
                .foregroundStyle(dbColor(muted: muted))
                .frame(maxWidth: .infinity)
                .frame(height: isCompact ? 20 : 24)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(dbBorder, lineWidth: 1))

            if isMaster {
                Button {
                    mixer.presentedScreen = .channel(strip.kind)
                } label: {
                    Text(strip.kind == .main ? L("EQ · Dyn") : L("Bus EQ · Dyn"))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.textControl)
                        .frame(maxWidth: .infinity)
                        .frame(height: isCompact ? 28 : 40)
                        .background(Theme.control, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            if isCompact {
                HStack(spacing: 3) { soloButton; muteButton }
            } else {
                soloButton
                muteButton
            }
        }
        .padding(.horizontal, isMaster ? 8 : 6)
        .padding(.bottom, 6)
        .frame(width: isMaster ? 112 : 78)
        .background(stripFill, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(stripBorder(isSelected: isSelected), lineWidth: isSelected ? 1.5 : 1)
        }
        .overlay {
            if strip.changedElsewhere {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(hex: 0xEBEBEB, opacity: 0.55), lineWidth: 2)
                    .shadow(color: Color(hex: 0xEBEBEB, opacity: 0.18), radius: 11)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if strip.changedElsewhere {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(Theme.background)
                    .frame(width: 16, height: 16)
                    .background(Color(hex: 0xEBEBEB), in: Circle())
                    .padding(.top, 9)
                    .padding(.trailing, 5)
                    .accessibilityLabel("Changed on another device")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .animation(.easeOut(duration: 0.25), value: strip.changedElsewhere)
    }

    // MARK: - Parts

    @ViewBuilder
    private var soloButton: some View {
        if strip.soloAddress != nil {
            StripButton(title: L("SOLO"), isOn: strip.isSoloed, style: .solo, height: isCompact ? 34 : 40,
                        isCompact: isCompact, accessibilityLabel: L("Solo \(strip.displayName)")) {
                mixer.toggleSolo(strip)
            }
        }
    }

    private var isSendsMode: Bool {
        if case .send = control { return true }
        return false
    }

    @ViewBuilder
    private var muteButton: some View {
        if isSendsMode {
            // In a monitor mix the button takes the channel out of that mix; it never mutes the room.
            let removed = mixer.isSendRemoved(strip, control)
            StripButton(title: isCompact ? "✕" : (removed ? L("REMOVED") : L("REMOVE")), isOn: removed, style: .mute,
                        height: isCompact ? 34 : 44, isCompact: isCompact,
                        accessibilityLabel: L("Remove \(strip.displayName) from this mix")) {
                mixer.toggleSendRemoved(strip, control)
            }
        } else {
            StripButton(title: L("MUTE"), isOn: !strip.isOn, style: .mute, height: isCompact ? 34 : 44,
                        isCompact: isCompact, silencedBy: strip.isOn ? mixer.silencedBy(strip) : nil,
                        accessibilityLabel: L("Mute \(strip.displayName)")) {
                mixer.toggleMute(strip)
            }
        }
    }

    private var barColor: Color {
        if isMaster, case .main = strip.kind { return Color(hex: 0xEBEBEB) }
        return busColor.map { isMaster ? $0 : strip.color } ?? strip.color
    }

    private func header(muted: Bool) -> some View {
        Button {
            mixer.selectedStrip = strip.kind
            mixer.presentedScreen = .channel(strip.kind)
        } label: {
            VStack(spacing: 2) {
                Text(isMaster ? masterTag : strip.shortLabel)
                    .font(Theme.mono(11, .regular))
                    .tracking(isMaster ? 0.6 : 0)
                    .foregroundStyle(Theme.textTertiary)
                Text(strip.displayName)
                    .font(Theme.rounded(isMaster ? 14 : 13, isMaster ? .heavy : .bold))
                    .foregroundStyle(muted ? Theme.textMuted : strip.isNamed || isMaster ? Theme.textPrimary : Color(hex: 0x7C818B))
                    .multilineTextAlignment(.center)
                    .lineLimit(isCompact ? 1 : 2)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .frame(height: isCompact ? 32 : 44, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isMaster ? L("Open \(strip.displayName) processing") : L("Select \(strip.displayName)"))
            }

    private var masterTag: String {
        switch strip.kind {
        case .main: return L("MAIN")
        case .bus(let number): return L("BUS \(number)")
        case .fxSend(let number): return L("FX \(number)")
        default: return strip.shortLabel
        }
    }

    private var processingPills: some View {
        HStack(spacing: 4) {
            Pill(text: "G", isOn: strip.gateOn, onColor: Theme.meterGreen, onText: Color(hex: 0x6FE597))
            Pill(text: "C", isOn: strip.compressorOn, onColor: Theme.meterAmber, onText: Theme.amberText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gate \(strip.gateOn ? "on" : "off"), compressor \(strip.compressorOn ? "on" : "off")")
    }

    @ViewBuilder
    private var meters: some View {
        if let right = strip.meterRight {
            // Narrower pair so the fader cap stays clear of the meters on a 78 pt strip.
            HStack(spacing: 2) {
                MeterView(level: strip.meter, peak: strip.peak).frame(width: isMaster ? 7 : 5)
                MeterView(level: right, peak: strip.peak).frame(width: isMaster ? 7 : 5)
            }
        } else {
            MeterView(level: strip.meter, peak: strip.peak).frame(width: 7)
        }
    }

    private var stripFill: Color {
        if let busColor { return busColor.opacity(isMaster ? 0.16 : 0.10) }
        return Theme.strip
    }

    private func stripBorder(isSelected: Bool) -> Color {
        if isSelected { return Theme.accent }
        if let busColor { return busColor.opacity(isMaster ? 0.55 : 0.32) }
        return isMaster ? Theme.borderStrong : Theme.border
    }

    private func dbColor(muted: Bool) -> Color {
        if muted { return Theme.textMuted }
        if isDragging { return Theme.accent }
        if strip.changedElsewhere { return .white }
        return Theme.textBright
    }

    private var dbBorder: Color {
        if isDragging { return Theme.accent.opacity(0.6) }
        if strip.changedElsewhere { return Color(hex: 0xEBEBEB, opacity: 0.6) }
        return Color.white.opacity(0.08)
    }

    private var faderLabel: String {
        switch control {
        case .fader:
            return L("\(strip.displayName) fader")
        case .send:
            return L("\(strip.displayName) send to \(mixer.master(for: mixer.selectedMix).displayName)")
        }
    }
}

/// Small status pill, e.g. G (gate) and C (compressor).
struct Pill: View {
    let text: String
    let isOn: Bool
    let onColor: Color
    let onText: Color

    var body: some View {
        Text(text)
            .font(Theme.mono(10, .bold))
            .foregroundStyle(isOn ? onText : Theme.textDim)
            .frame(maxWidth: .infinity)
            .frame(height: 18)
            .background(isOn ? onColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(isOn ? onColor.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 1))
    }
}

/// SOLO and MUTE buttons.
struct StripButton: View {
    enum Style { case mute, solo }

    let title: String
    let isOn: Bool
    let style: Style
    let height: CGFloat
    var isCompact = false
    /// "G1" or "DCA2" when something else is silencing this strip while its own MUTE is off.
    var silencedBy: String?
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        let silenced = silencedBy != nil && !isOn
        Button(action: action) {
            VStack(spacing: 0) {
                Text(title)
                    .font(.system(size: isCompact ? 9 : (silenced ? 9 : 11), weight: .heavy))
                    .tracking(isCompact ? 0 : 0.8)
                if let silencedBy, silenced, !isCompact {
                    Text(silencedBy)
                        .font(Theme.mono(10, .bold))
                        .foregroundStyle(Theme.mute)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(isOn ? onColor : Theme.control, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(silenced ? Theme.mute : border, lineWidth: silenced ? 1.5 : 1))
            .shadow(color: isOn ? onColor.opacity(style == .mute ? 0.45 : 0.35) : .clear,
                    radius: style == .mute ? 9 : 7)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .medium), trigger: isOn)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isOn ? "on" : (silencedBy.map { L("silenced by \($0)") } ?? "off"))
    }

    private var onColor: Color { style == .mute ? Theme.mute : Theme.solo }

    private var foreground: Color {
        guard isOn else { return style == .mute ? Theme.textControl : Theme.textSecondary }
        return style == .mute ? .white : Theme.onSolo
    }

    private var border: Color {
        guard isOn else { return Color.white.opacity(0.08) }
        return style == .mute ? Theme.muteBorder : Theme.solo
    }
}

/// Pan position as an arc: centre at the top, left and right along the curve.
struct PanArc: View {
    /// 0...1, 0.5 = centre.
    let pan: Float

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: 24)
            let radius: CGFloat = 20
            // Angle 0 = straight up, -90 = hard left, +90 = hard right.
            func point(_ degrees: Double) -> CGPoint {
                let radians = degrees * .pi / 180
                return CGPoint(x: center.x + radius * CGFloat(sin(radians)),
                               y: center.y - radius * CGFloat(cos(radians)))
            }
            func arc(from start: Double, to end: Double) -> Path {
                var path = Path()
                let steps = 24
                for step in 0...steps {
                    let p = point(start + (end - start) * Double(step) / Double(steps))
                    if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                return path
            }
            let rounded = StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
            context.stroke(arc(from: -90, to: 90), with: .color(.white.opacity(0.14)), style: rounded)

            let amount = Double(pan) * 2 - 1
            if abs(amount) > 0.01 {
                context.stroke(arc(from: 0, to: amount * 90), with: .color(Theme.textControl), style: rounded)
            }
            let dot = point(amount * 90)
            context.fill(Path(ellipseIn: CGRect(x: dot.x - 3.5, y: dot.y - 3.5, width: 7, height: 7)),
                         with: .color(Theme.textPrimary))
            context.draw(Text(label).font(Theme.mono(9, .semibold)).foregroundStyle(Theme.textTertiary),
                         at: CGPoint(x: center.x, y: 22), anchor: .center)
        }
        .accessibilityElement()
        .accessibilityLabel("Pan")
        .accessibilityValue(label)
    }

    private var label: String {
        let amount = Int((Double(pan) * 2 - 1) * 100)
        if amount == 0 { return "C" }
        return (amount < 0 ? "L" : "R") + "\(abs(amount))"
    }
}
