import SwiftUI

struct ChannelStripView: View {
    @Environment(Mixer.self) private var mixer
    let strip: Strip
    /// What the fader controls: the strip's own fader or one of its sends.
    let control: LevelControl
    /// Colour of the selected bus when the faders show sends.
    let accent: Color?

    var body: some View {
        let level = strip.level(control)

        VStack(spacing: 8) {
            Text(strip.displayName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(strip.color.opacity(0.9), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(strip.labelTextColor)

            HStack(spacing: 6) {
                MeterView(level: strip.meter)
                    .frame(width: 6)
                FaderView(
                    value: level,
                    accent: accent,
                    label: faderLabel,
                    onTouchingChanged: { mixer.setTouching(strip, control, $0) },
                    onChange: { mixer.setLevel(strip, control, to: $0) }
                )
            }

            Text(formatDecibels(level))
                .font(.caption.monospacedDigit())
                .foregroundStyle(accent ?? .secondary)

            Button {
                mixer.toggleMute(strip)
            } label: {
                Text("MUTE")
                    .font(.caption.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(strip.isOn ? Color(white: 0.2) : Color.red,
                                in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(strip.isOn ? Color.secondary : Color.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(strip.isOn ? "Mute \(strip.displayName)" : "Unmute \(strip.displayName)")
        }
        .frame(width: 76)
        .padding(6)
        .background(stripBackground, in: RoundedRectangle(cornerRadius: 10))
    }

    private var stripBackground: Color {
        if let accent, control != .fader {
            return accent.opacity(0.12)
        }
        return Color(white: 0.11)
    }

    private var faderLabel: String {
        switch control {
        case .fader:
            return "\(strip.displayName) fader"
        case .send:
            return "\(strip.displayName) send to \(mixer.master(for: mixer.selectedMix).displayName)"
        }
    }
}

struct MeterView: View {
    /// Level in dBFS; the meter shows -60...0.
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            let fraction = CGFloat(min(max((level + 60) / 60, 0), 1))
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(white: 0.18))
                LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .bottom, endPoint: .top)
                    .mask(alignment: .bottom) {
                        Rectangle().frame(height: geometry.size.height * fraction)
                    }
            }
        }
        .accessibilityHidden(true)
    }
}
