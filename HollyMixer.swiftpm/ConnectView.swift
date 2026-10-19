import SwiftUI
import UIKit

struct ConnectView: View {
    @Environment(Mixer.self) private var mixer
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Binding var host: String
    @AppStorage("recentMixers") private var recentJSON = "[]"

    @State private var found: [DiscoveredMixer] = []
    @State private var isScanning = false
    @State private var check: NetworkCheck?
    @State private var isChecking = false
    @State private var path = NetworkPathInfo()

    var body: some View {
        let columns = sizeClass == .regular
        ScrollView {
            Group {
                if columns {
                    HStack(alignment: .top, spacing: 24) {
                        mainColumn.frame(maxWidth: .infinity)
                        sideColumn.frame(maxWidth: 480)
                    }
                } else {
                    VStack(spacing: 24) {
                        mainColumn
                        sideColumn
                    }
                }
            }
            .padding(.horizontal, columns ? 56 : 16)
            .padding(.vertical, columns ? 48 : 24)
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.textPrimary)
        .task { await scan() }
    }

    // MARK: - Main column

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                HollyMixerLogo(size: 32)
                    .frame(width: 56, height: 56)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect to a mixer")
                        .font(.system(size: 32, weight: .bold))
                        .tracking(-0.4)
                    Text("Works with XR18 over Wi-Fi or LAN. More than one iPad can be connected at once.")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                LanguageMenu()
            }

            if mixer.status != .disconnected {
                connectingCard
            }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("FOUND ON THIS NETWORK").sectionLabelStyle()
                    Spacer()
                    Button {
                        Task { await scan() }
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(isScanning ? Theme.meterGreen : Theme.textDim)
                                .frame(width: 7, height: 7)
                            Text(isScanning ? L("Scanning") : L("Scan again"))
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(isScanning)
                }
                .padding(.horizontal, 18)
                .frame(height: 44)
                divider

                if found.isEmpty {
                    Text(isScanning ? L("Looking for mixers…") : L("No mixer answered. Check that this device is on the same network as the mixer, or type its IP address below."))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                    divider
                }
                ForEach(found) { mixerInfo in
                    foundRow(mixerInfo)
                    divider
                }

                HStack(alignment: .bottom, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("OR TYPE AN IP ADDRESS").sectionLabelStyle()
                        TextField("192.168.1.2", text: $host)
                            .keyboardType(.decimalPad)
                            .font(Theme.mono(16, .regular))
                            .padding(.horizontal, 14)
                            .frame(height: 48)
                            .background(Theme.background, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.12), lineWidth: 1))
                            .accessibilityLabel("Mixer IP address")
                    }
                    Button("Connect") {
                        connect(to: host.trimmingCharacters(in: .whitespaces))
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textBright)
                    .padding(.horizontal, 18)
                    .frame(height: 48)
                    .background(Theme.control, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.borderStrong, lineWidth: 1))
                    .buttonStyle(.plain)
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border, lineWidth: 1))

            let recent = RecentMixer.load(from: recentJSON)
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("RECENT").sectionLabelStyle()
                    HStack(spacing: 10) {
                        ForEach(recent.prefix(3)) { item in
                            Button {
                                host = item.ip
                                connect(to: item.ip)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name)
                                        .font(.system(size: 14, weight: .semibold))
                                    Text("\(item.ip) · \(item.lastUsed.formatted(.relative(presentation: .named).locale(ActiveLanguage.locale)))")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Button {
                mixer.startDemo()
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "play")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xB794FF))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Try the demo mixer")
                            .font(.system(size: 16, weight: .bold))
                        Text("Practise safely — nothing you touch reaches the room.")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: 0xB9A6E0))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .bold))
                }
                .foregroundStyle(Color(hex: 0xE2D4FF))
                .padding(.horizontal, 20)
                .frame(height: 64)
                .background(Theme.demo.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.demo.opacity(0.55), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private var connectingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(Theme.accentText)
            VStack(alignment: .leading, spacing: 2) {
                Text("Connecting to \(mixer.host)…")
                    .font(.system(size: 15, weight: .semibold))
                if case .waitingForNetwork = mixer.status {
                    Text("If iOS asked for Local Network access, tap Allow.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            Button("Cancel") {
                mixer.disconnect()
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.accentText)
            .frame(minHeight: 44)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.accent.opacity(0.5), lineWidth: 1))
    }

    private func foundRow(_ info: DiscoveredMixer) -> some View {
        let isLastUsed = RecentMixer.load(from: recentJSON).first?.ip == info.ip
        let isPrimary = isLastUsed || found.first == info
        return Button {
            host = info.ip
            connect(to: info.ip)
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "slider.horizontal.below.rectangle")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.textControl)
                    .frame(width: 48, height: 48)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    Text(info.name)
                        .font(.system(size: 17, weight: .semibold))
                    Text("\(info.model) · fw \(info.firmware) · \(info.ip) · \(info.latency) ms")
                        .font(Theme.mono(13, .regular))
                        .foregroundStyle(Theme.textTertiary)
                }
                .lineLimit(1)
                Spacer()
                if info.isFirmwareOutdated {
                    Text("Firmware \(info.firmware)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.amberText)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Theme.meterAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.meterAmber.opacity(0.4), lineWidth: 1))
                }
                if isLastUsed {
                    Text("Last used")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accentText)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent.opacity(0.4), lineWidth: 1))
                }
                Text("Connect")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(isPrimary ? Theme.onAccent : Theme.textBright)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(isPrimary ? Theme.accent : Theme.control, in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal, 18)
            .frame(height: 84)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Side column

    private var sideColumn: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Check my network")
                        .font(.system(size: 20, weight: .bold))
                    Spacer()
                    Button(isChecking ? L("Checking…") : check == nil ? L("Run") : L("Run again")) {
                        Task { await runCheck() }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textBright)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(Theme.control, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.borderStrong, lineWidth: 1))
                    .buttonStyle(.plain)
                    .disabled(isChecking || checkTarget.isEmpty)
                }
                checkRows
            }
            .padding(20)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border, lineWidth: 1))

            isolationCard

            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "globe")
                    .font(.system(size: 20))
                    .foregroundStyle(Color(hex: 0x8CB4FF))
                    .frame(width: 44, height: 44)
                    .background(Color(hex: 0x528FFA, opacity: 0.16), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Why “Local Network” access?")
                        .font(.system(size: 15, weight: .bold))
                    Text("Holly Mixer only talks to mixers in this building. If you tapped “Don't Allow”, turn it on in Settings › Privacy & Security › Local Network.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accentText)
                    .frame(minHeight: 36)
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border, lineWidth: 1))
        }
    }

    /// Shown when the mixer can't be seen: the usual cause on church networks.
    @ViewBuilder
    private var isolationCard: some View {
        let unreachable = (check.map { !$0.isReachable } ?? false) || (found.isEmpty && !isScanning)
        if unreachable {
            VStack(alignment: .leading, spacing: 8) {
                Text("Can't see the mixer?")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(hex: 0xFFE4A0))
                Text("Guest Wi-Fi networks often block devices from seeing each other. Join the same network as the mixer (for example the staff network), then scan again.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: 0xE9D7A5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.meterAmber.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.meterAmber.opacity(0.4), lineWidth: 1))
        }
    }

    @ViewBuilder
    private var checkRows: some View {
        checkRow(ok: path.isGood, label: path.title, hint: path.hint, value: path.isGood ? L("on") : L("off"))
        if let check {
            checkRow(ok: check.isReachable, label: L("Mixer reachable"),
                     hint: check.isReachable ? L("\(check.host) answered on the control port") : L("\(check.host) did not answer"),
                     value: check.isReachable ? L("yes") : L("no"))
            checkRow(ok: (check.latency ?? 999) < 20, label: L("Latency"), hint: L("Below 20 ms feels instant"),
                     value: check.latency.map { "\($0) ms" } ?? "—")
            checkRow(ok: check.lossPercent < 5, label: L("Packet loss"), hint: L("Over \(check.attempts) pings"),
                     value: String(format: "%.1f %%", check.lossPercent))
        } else {
            Text("Tests the connection to \(checkTarget.isEmpty ? L("the mixer") : checkTarget): whether it answers, how fast, and how many messages get lost.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func checkRow(ok: Bool, label: String, hint: String, value: String) -> some View {
        let color = ok ? Theme.meterGreen : Theme.meterAmber
        return HStack(spacing: 12) {
            Text(ok ? "✓" : "!")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(ok ? Color(hex: 0x6FE597) : Theme.amberText)
                .frame(width: 24, height: 24)
                .background(color.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 14, weight: .semibold))
                Text(hint).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Text(value)
                .font(Theme.mono(14))
                .foregroundStyle(ok ? Theme.textBright : Theme.amberText)
        }
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
    }

    // MARK: - Actions

    private func connect(to address: String) {
        guard !address.isEmpty else { return }
        mixer.connect(host: address)
    }

    private func scan() async {
        guard !isScanning else { return }
        isScanning = true
        let recentHosts = RecentMixer.load(from: recentJSON).map(\.ip)
        found = await MixerDiscovery.scan(alsoTry: recentHosts + [host])
        isScanning = false
    }

    /// The typed address, or else the mixer found by the scan, so the check never tests an address nobody chose.
    private var checkTarget: String {
        let typed = host.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? (found.first?.ip ?? "") : typed
    }

    private func runCheck() async {
        let target = checkTarget
        guard !target.isEmpty else { return }
        isChecking = true
        check = await MixerDiscovery.check(host: target)
        isChecking = false
    }
}
