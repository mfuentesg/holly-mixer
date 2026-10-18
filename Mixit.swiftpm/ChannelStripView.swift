import SwiftUI

struct ChannelStripView: View {
    @Environment(Mixer.self) private var mixer
    let strip: Strip
    /// What the fader controls: the strip's own fader or one of its sends.
    let control: LevelControl
    /// Colour of the selected bus when the faders show sends.
    let accent: Color?
    var width: CGFloat = 78

    var body: some View {
        let level = strip.level(control)
        let tint = accent ?? strip.color

        VStack(spacing: 10) {
            header

            HStack(spacing: 4) {
                FaderView(
                    value: level,
                    tint: tint,
                    isDimmed: !strip.isOn,
                    label: faderLabel,
                    onTouchingChanged: { mixer.setTouching(strip, control, $0) },
                    onChange: { mixer.setLevel(strip, control, to: $0) }
                )
                MeterView(level: strip.meter)
                    .frame(width: 5)
                    .padding(.vertical, 22)
            }

            Text(formatDecibels(level))
                .font(.system(.caption, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundStyle(accent ?? Color.white.opacity(0.75))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(Theme.control, in: Capsule())

            MuteButton(isMuted: !strip.isOn, name: strip.displayName) {
                mixer.toggleMute(strip)
            }
        }
        .padding(.horizontal, 7)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(width: width)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(stripBackground)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.cardBorder, lineWidth: 1))
        }
    }

    private var header: some View {
        VStack(spacing: 3) {
            Capsule()
                .fill(strip.color)
                .frame(height: 4)
                .padding(.horizontal, 10)
                .shadow(color: strip.color.opacity(0.6), radius: 4)
            Text(strip.shortLabel)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Text(strip.displayName)
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .foregroundStyle(strip.isOn ? Color.white : Color.white.opacity(0.45))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
    }

    private var stripBackground: some ShapeStyle {
        if let accent, control != .fader {
            return AnyShapeStyle(LinearGradient(
                colors: [accent.opacity(0.16), Theme.card],
                startPoint: .top, endPoint: .bottom
            ))
        }
        return AnyShapeStyle(Theme.card)
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

struct MuteButton: View {
    let isMuted: Bool
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("MUTE")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(isMuted ? Color.white : Color.white.opacity(0.5))
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isMuted
                          ? AnyShapeStyle(LinearGradient(colors: [Theme.mute, Theme.mute.opacity(0.75)],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Theme.control))
                    .shadow(color: isMuted ? Theme.mute.opacity(0.55) : .clear, radius: 6)
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(isMuted ? 0.25 : 0.06), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .medium), trigger: isMuted)
        .accessibilityLabel(isMuted ? "Unmute \(name)" : "Mute \(name)")
    }
}

/// LED-style segmented meter, -60...0 dBFS.
struct MeterView: View {
    let level: Float

    var body: some View {
        Canvas { context, size in
            let segments = max(min(Int(size.height / 6), 48), 8)
            let segmentHeight = size.height / CGFloat(segments)
            let lit = Int((min(max((level + 60) / 60, 0), 1) * Float(segments)).rounded())
            for index in 0..<segments {
                let db = -60 + Float(index) / Float(segments) * 60
                let color = db >= -6 ? Theme.meterRed : db >= -18 ? Theme.meterAmber : Theme.meterGreen
                let rect = CGRect(
                    x: 0,
                    y: size.height - CGFloat(index + 1) * segmentHeight,
                    width: size.width,
                    height: segmentHeight - 1.5
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 1),
                    with: .color(index < lit ? color : color.opacity(0.1))
                )
            }
        }
        .accessibilityHidden(true)
    }
}
