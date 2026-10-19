import SwiftUI

/// Settings page for the four mute groups: which strips belong to each, and a button to fire the group.
/// The group buttons in the mixer's top bar silence every strip listed here.
struct MuteGroupsView: View {
    @Environment(Mixer.self) private var mixer

    private var members: [Strip] { mixer.channels + [mixer.auxIn] + mixer.fxReturns + mixer.buses }

    var body: some View {
        VStack(spacing: 0) {
            ScreenTopBar(title: L("Mute groups"),
                         subtitle: L("Choose which channels each group silences. Then use the group buttons to mute them together."))
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(1...4, id: \.self) { number in
                        groupCard(number)
                    }
                }
                .padding(20)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.textPrimary)
        .task { mixer.request(members.map { "\($0.base)/grp/mute" }) }
    }

    private func groupCard(_ number: Int) -> some View {
        let bit = 1 << (number - 1)
        let isOn = mixer.muteGroups[number - 1]
        let count = members.filter { mixer.muteGroupMask(of: $0) & bit != 0 }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Mute group \(number)")).font(.system(size: 17, weight: .bold))
                    Text(count == 1 ? L("1 channel") : L("\(count) channels"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Button {
                    mixer.toggleMuteGroup(number)
                } label: {
                    Text(isOn ? L("Group is muted · tap to release") : L("Mute this group"))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(isOn ? .white : Theme.textBright)
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(isOn ? Theme.mute : Theme.control, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(isOn ? Theme.muteBorder : Theme.borderStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                ForEach(members) { strip in
                    chip(strip, group: number, bit: bit)
                }
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border, lineWidth: 1))
    }

    private func chip(_ strip: Strip, group: Int, bit: Int) -> some View {
        let isMember = mixer.muteGroupMask(of: strip) & bit != 0
        return Button {
            mixer.setMuteGroupMembership(strip, group: group, member: !isMember)
        } label: {
            HStack(spacing: 6) {
                Circle().fill(strip.color).frame(width: 8, height: 8)
                Text(strip.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(isMember ? .white : Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(isMember ? Theme.mute.opacity(0.85) : Theme.control, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(isMember ? Theme.muteBorder : Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(strip.displayName), \(L("Mute group \(group)"))")
        .accessibilityValue(isMember ? L("yes") : L("no"))
    }
}
