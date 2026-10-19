import SwiftUI
import UIKit

/// One page that lists everything that isn't a fader, each item with a plain description.
/// Opened by the always-visible "Settings" button in the top bar.
struct SettingsHubView: View {
    @Environment(Mixer.self) private var mixer
    @Environment(Localization.self) private var localization
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// iPhone in portrait scans the pairing code; the iPad (and landscape) shows the code.
    private var scansPairingCode: Bool { UIDevice.current.userInterfaceIdiom == .phone && verticalSizeClass != .compact }

    var body: some View {
        VStack(spacing: 0) {
            ScreenTopBar(title: L("Settings"), subtitle: L("Everything that isn't a fader, in one place."))
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    group(L("MIXING"), rows: [
                        row("speaker.slash", L("Mute groups"),
                            L("Choose which channels each of the 4 groups silences together."), .muteGroups),
                    ])
                    group(L("SAFETY"), rows: [
                        row("clock.arrow.circlepath", L("Settings backup"),
                            L("Saved copies of every setting; restore them if the mixer forgets them."), .backups),
                        row("camera.on.rectangle", L("Mixer snapshots"),
                            L("The 64 memories stored inside the mixer itself."), .snapshots),
                    ])
                    group(L("MUSICIANS"), rows: [pairRow])
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("LANGUAGE")).sectionLabelStyle()
                        Picker("Language", selection: Bindable(localization).language) {
                            ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    Button {
                        mixer.presentedScreen = nil
                        mixer.disconnect()
                    } label: {
                        Label(mixer.isDemo ? L("Exit demo") : L("Disconnect from mixer"), systemImage: "power")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.accentText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.textPrimary)
    }

    private var pairRow: SettingsRow {
        if scansPairingCode {
            return SettingsRow(icon: "qrcode.viewfinder", title: L("Pair as musician…"),
                               detail: L("Scan the code on the sound desk's iPad to control only your own monitor mix.")) {
                mixer.presentedScreen = nil
                mixer.showsPairingScanner = true
            }
        }
        return row("qrcode", L("Pair a musician's iPhone"),
                   L("Shows a code that locks a musician's iPhone to one monitor mix."), .monitorPairing)
    }

    private func row(_ icon: String, _ title: String, _ detail: String, _ screen: Screen) -> SettingsRow {
        SettingsRow(icon: icon, title: title, detail: detail) { mixer.presentedScreen = screen }
    }

    private func group(_ title: String, rows: [SettingsRow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).sectionLabelStyle()
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    rows[index]
                    if index < rows.count - 1 {
                        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                    }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border, lineWidth: 1))
        }
    }
}

struct SettingsRow: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 19))
                    .foregroundStyle(Theme.textControl)
                    .frame(width: 44, height: 44)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
