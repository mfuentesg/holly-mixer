import SwiftUI

/// A DCA group as a strip on the iPad mixer: one fader and a mute for every channel assigned to it.
struct DCAStripView: View {
    @Environment(Mixer.self) private var mixer
    let group: DCAGroup
    @State private var isDragging = false

    private var memberCount: Int {
        let bit = 1 << (group.number - 1)
        return (mixer.channels + [mixer.auxIn] + mixer.fxReturns + mixer.buses).filter { mixer.dcaMask(of: $0) & bit != 0 }.count
    }

    var body: some View {
        let muted = !group.isOn
        VStack(spacing: 6) {
            Rectangle()
                .fill(group.color)
                .opacity(muted ? 0.35 : 1)
                .frame(height: 4)
                .padding(.horizontal, -6)
            VStack(spacing: 2) {
                Text("DCA \(group.number)")
                    .font(Theme.mono(10, .regular))
                    .foregroundStyle(Theme.textTertiary)
                Text(group.displayName)
                    .font(Theme.rounded(14))
                    .foregroundStyle(muted ? Theme.textMuted : Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                Text(memberCount == 1 ? L("1 channel") : L("\(memberCount) channels"))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(height: 66)
            FaderView(
                value: group.fader,
                lineColor: group.color,
                capLineColor: group.color,
                isMuted: muted,
                label: L("\(group.displayName) fader"),
                isDragging: $isDragging,
                onTouchingChanged: { mixer.beginDCA(group, touching: $0) },
                onChange: { mixer.setDCALevel(group, to: $0) }
            )
            .frame(maxHeight: .infinity)
            Text(formatDecibels(group.fader))
                .font(Theme.mono(12))
                .foregroundStyle(muted ? Theme.textMuted : Theme.textBright)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 6))
            StripButton(title: L("MUTE"), isOn: muted, style: .mute, height: 44,
                        accessibilityLabel: L("Mute \(group.displayName)")) {
                mixer.toggleDCAMute(group)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        .frame(width: 78)
        .background(Theme.strip, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.07), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// A DCA group as a row on the iPhone mixer: mute, name and a horizontal fader.
struct PhoneDCARow: View {
    @Environment(Mixer.self) private var mixer
    let group: DCAGroup

    var body: some View {
        let muted = !group.isOn
        HStack(spacing: 8) {
            PhoneToggleButton(title: "M", isOn: muted, style: .mute,
                              accessibilityLabel: L("Mute \(group.displayName)")) {
                mixer.toggleDCAMute(group)
            }
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(group.color.opacity(muted ? 0.4 : 1))
                        .frame(width: 4, height: 14)
                    Text("DCA \(group.number)")
                        .font(Theme.mono(11, .regular))
                        .foregroundStyle(Theme.textTertiary)
                    Text(group.displayName)
                        .font(Theme.rounded(15))
                        .foregroundStyle(muted ? Theme.textMuted : Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(formatDecibels(group.fader))
                        .font(Theme.mono(13, .bold))
                        .foregroundStyle(muted ? Theme.textMuted : Theme.textBright)
                }
                .frame(height: 22)
                PhoneHorizontalFader(
                    value: group.fader, lineColor: group.color, isMuted: muted, meterStrip: nil,
                    label: L("\(group.displayName) fader"),
                    onTouchingChanged: { mixer.beginDCA(group, touching: $0) },
                    onChange: { mixer.setDCALevel(group, to: $0) }
                )
                .frame(height: 36)
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .frame(height: 64)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.05), lineWidth: 1))
    }
}
