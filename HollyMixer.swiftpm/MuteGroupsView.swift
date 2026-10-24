import SwiftUI

/// Settings page for the four mute groups: which strips belong to each, and a button to fire the group.
/// The group buttons in the mixer's bottom bar silence every strip listed here.
struct MuteGroupsView: View {
    @Environment(Mixer.self) private var mixer
    @State private var selected = 1

    private var members: [Strip] { mixer.channels + [mixer.auxIn] + mixer.fxReturns + mixer.buses }

    private func count(in group: Int) -> Int {
        let bit = 1 << (group - 1)
        return members.filter { mixer.muteGroupMask(of: $0) & bit != 0 }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenTopBar(title: L("Mute groups"),
                         subtitle: L("Pick a group, then tap the channels it should silence. Tap again to remove one."))
            groupPicker
            ScrollView {
                groupCard(selected)
                    .padding(20)
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .textPageTypeSize()
        .foregroundStyle(Theme.textPrimary)
        .task { mixer.request(members.map { "\($0.base)/grp/mute" }) }
    }

    /// 1 2 3 4 with how many channels each group holds.
    private var groupPicker: some View {
        HStack(spacing: 8) {
            ForEach(1...4, id: \.self) { number in
                let isSelected = selected == number
                Button {
                    selected = number
                } label: {
                    VStack(spacing: 2) {
                        HStack(spacing: 5) {
                            if mixer.muteGroups[number - 1] {
                                Circle().fill(Theme.mute).frame(width: 8, height: 8)
                            }
                            Text(L("Group \(number)"))
                                .scaledFont(15, .bold)
                                .lineLimit(1)
                        }
                        Text(count(in: number) == 1 ? L("1 channel") : L("\(count(in: number)) channels"))
                            .scaledFont(11)
                            .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(isSelected ? Theme.controlSelected : Theme.strip, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(isSelected ? Theme.accent.opacity(0.7) : Theme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .frame(maxWidth: 940)
        .frame(maxWidth: .infinity)
    }

    private func groupCard(_ number: Int) -> some View {
        let bit = 1 << (number - 1)
        let included = members.filter { mixer.muteGroupMask(of: $0) & bit != 0 }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Channels in group \(number)")).scaledFont(17, .bold)
                    Text(included.isEmpty ? L("None yet") : included.map(\.displayName).joined(separator: " · "))
                        .scaledFont(12)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if !included.isEmpty {
                    Button(L("Clear all")) {
                        for strip in included { mixer.setMuteGroupMembership(strip, group: number, member: false) }
                    }
                    .scaledFont(13, .semibold)
                    .foregroundStyle(Theme.textControl)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    .buttonStyle(.plain)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                ForEach(members) { strip in
                    chip(strip, group: number, bit: bit)
                }
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border, lineWidth: 1))
    }

    /// One tap includes the channel in the group, another tap takes it out.
    private func chip(_ strip: Strip, group: Int, bit: Int) -> some View {
        let isMember = mixer.muteGroupMask(of: strip) & bit != 0
        return Button {
            mixer.setMuteGroupMembership(strip, group: group, member: !isMember)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isMember ? "checkmark.circle.fill" : "circle")
                    .scaledFont(15)
                    .foregroundStyle(isMember ? Theme.accent : Theme.textDim)
                Circle().fill(strip.color).frame(width: 8, height: 8)
                Text(strip.displayName)
                    .scaledFont(13, .semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isMember ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(isMember ? Theme.controlSelected : Theme.control, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(isMember ? Theme.accent.opacity(0.8) : Color.white.opacity(0.08), lineWidth: isMember ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(strip.displayName), \(L("Mute group \(group)"))")
        .accessibilityValue(isMember ? L("yes") : L("no"))
        .accessibilityAddTraits(isMember ? .isSelected : [])
    }
}
