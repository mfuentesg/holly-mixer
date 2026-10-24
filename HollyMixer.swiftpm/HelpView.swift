import SwiftUI

/// A short guide for volunteers: the four things people ask during a service.
struct HelpView: View {
    private struct Topic: Identifiable {
        let id: Int
        let icon: String
        let title: String
        let steps: [String]
    }

    private var topics: [Topic] {
        [
            Topic(id: 1, icon: "speaker.slash", title: L("Why is there no sound from a channel?"), steps: [
                L("Look at the channel's MUTE button. Red means it is muted."),
                L("A red outline with G1 or DCA2 means a mute group or a DCA is silencing it. Press that group at the bottom (or the DCA's MUTE) to release it."),
                L("A dim fader with no mute is usually a fader pulled down, or a channel whose input is off on the mixer."),
            ]),
            Topic(id: 2, icon: "headphones", title: L("Change what a musician hears"), steps: [
                L("In the MIX row, pick their monitor (for example IEM Batería)."),
                L("The faders now control what goes into their ears. The room does not change."),
                L("The ✕ / REMOVE button takes a channel out of their mix. Tap it again to bring it back."),
                L("Tap Main LR, or Back to Main in the blue banner, to return to the room mix."),
            ]),
            Topic(id: 3, icon: "rectangle.3.group", title: L("Mute groups"), steps: [
                L("Settings › Mute groups: pick a group, then tap the channels it should silence."),
                L("The four buttons at the bottom mute or release a whole group at once."),
            ]),
            Topic(id: 4, icon: "clock.arrow.circlepath", title: L("The mixer lost its settings"), steps: [
                L("After the mixer is switched off and on, a banner offers to restore the last saved settings."),
                L("Tap Review and restore, check the list, then Restore. Do it when the band is not playing."),
                L("Settings › Settings backup keeps every saved copy."),
            ]),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenTopBar(title: L("Help"), subtitle: L("The four things people ask during a service."))
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(topics) { topic in
                        card(topic)
                    }
                }
                .padding(20)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .textPageTypeSize()
        .foregroundStyle(Theme.textPrimary)
    }

    private func card(_ topic: Topic) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: topic.icon)
                    .scaledFont(18)
                    .foregroundStyle(Theme.textControl)
                    .frame(width: 40, height: 40)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                Text(topic.title).scaledFont(17, .bold)
            }
            ForEach(Array(topic.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(Theme.mono(12, .bold))
                        .foregroundStyle(Theme.accentText)
                        .frame(width: 20, height: 20)
                        .background(Theme.accent.opacity(0.14), in: Circle())
                    Text(step)
                        .scaledFont(14)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border, lineWidth: 1))
    }
}
