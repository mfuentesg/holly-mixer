import SwiftUI

struct MixerView: View {
    @Environment(Mixer.self) private var mixer

    var body: some View {
        let target = mixer.selectedMix
        let master = mixer.master(for: target)
        let control = target.control
        let accent: Color? = target == .main ? nil : master.color

        VStack(spacing: 0) {
            topBar
            MixSelector()
            if target != .main {
                sendsBanner(master)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(mixer.inputs.filter { $0.hasControl(control) }) { strip in
                                    ChannelStripView(strip: strip, control: control, accent: accent)
                                }
                                if target == .main {
                                    Rectangle()
                                        .fill(Theme.cardBorder)
                                        .frame(width: 1)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 20)
                                    ForEach(mixer.buses + mixer.fxSends) { strip in
                                        ChannelStripView(strip: strip, control: .fader, accent: nil)
                                    }
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                        }
                        bankBar(proxy: proxy, showMasters: target == .main)
                    }
                }
                ChannelStripView(strip: master, control: .fader, accent: accent, width: 96)
                    .padding(10)
                    .background(Theme.bar.opacity(0.6))
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.cardBorder).frame(width: 1)
                    }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.2), value: target)
    }

    /// Buttons that jump the strip row to a group of strips.
    private func bankBar(proxy: ScrollViewProxy, showMasters: Bool) -> some View {
        var banks = [
            Bank(title: "1–8", first: .channel(1)),
            Bank(title: "9–16", first: .channel(9)),
            Bank(title: "Aux · FX", first: .auxIn),
        ]
        if showMasters {
            banks.append(Bank(title: "Buses · FX Sends", first: .bus(1)))
        }
        return HStack(spacing: 6) {
            ForEach(banks) { bank in
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(bank.first, anchor: .leading)
                    }
                } label: {
                    Text(bank.title)
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Theme.control, in: Capsule())
                        .overlay(Capsule().stroke(Theme.cardBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.8))
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func sendsBanner(_ master: Strip) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .foregroundStyle(master.color)
            Text("Faders are sends to **\(master.displayName)**")
            Spacer()
            Button {
                mixer.selectedMix = .main
            } label: {
                Label("Back to Main", systemImage: "xmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(master.color)
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(master.color.opacity(0.14))
        .overlay(alignment: .bottom) {
            Rectangle().fill(master.color.opacity(0.5)).frame(height: 1)
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "slider.vertical.3")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(mixer.mixerName.isEmpty ? mixer.host : mixer.mixerName)
                    .font(.system(.headline, design: .rounded))
                Text("\(mixer.model) · v\(mixer.firmware) · \(mixer.host)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            statusPill
            Spacer()
            Button {
                mixer.disconnect()
            } label: {
                Image(systemName: "power")
                    .font(.headline)
                    .frame(width: 38, height: 38)
                    .background(Theme.control, in: Circle())
                    .overlay(Circle().stroke(Theme.cardBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Disconnect")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.bar)
    }

    private var statusPill: some View {
        let connected = mixer.status == .connected
        let color = mixer.isDemo ? Color.purple : connected ? Theme.meterGreen : Color.orange
        let text = mixer.isDemo ? "Demo mixer" : connected ? "Connected" : "Reconnecting…"
        return HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color, radius: 3)
            Text(text)
                .font(.system(.caption, design: .rounded).weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
    }
}

private struct Bank: Identifiable {
    let title: String
    /// The strip the bank button scrolls to.
    let first: Strip.Kind

    var id: String { title }
}

/// Chips for Main LR, Bus 1-6 and FX 1-4; the selected mix decides what the faders control.
struct MixSelector: View {
    @Environment(Mixer.self) private var mixer

    private let targets: [MixTarget] = [.main]
        + (1...6).map { MixTarget.bus($0) }
        + (1...4).map { MixTarget.fxSend($0) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("MIX")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(.tertiary)
                ForEach(targets, id: \.self) { target in
                    chip(for: target)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Theme.bar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.cardBorder).frame(height: 1)
        }
    }

    private func chip(for target: MixTarget) -> some View {
        let strip = mixer.master(for: target)
        let isSelected = mixer.selectedMix == target
        return Button {
            mixer.selectedMix = target
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(strip.color)
                    .frame(width: 8, height: 8)
                Text(strip.displayName)
                    .font(.system(.subheadline, design: .rounded).weight(isSelected ? .bold : .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.7))
            .background(isSelected ? strip.color.opacity(0.3) : Theme.control, in: Capsule())
            .overlay(Capsule().stroke(isSelected ? strip.color : Theme.cardBorder, lineWidth: isSelected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
