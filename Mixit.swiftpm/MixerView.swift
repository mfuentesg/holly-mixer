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
            Divider()
            MixSelector()
            if target != .main {
                sendsBanner(master)
            }
            Divider()
            HStack(spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(mixer.inputs.filter { $0.hasControl(control) }) { strip in
                            ChannelStripView(strip: strip, control: control, accent: accent)
                        }
                        if target == .main {
                            Divider()
                                .padding(.horizontal, 4)
                            ForEach(mixer.buses + mixer.fxSends) { strip in
                                ChannelStripView(strip: strip, control: .fader, accent: nil)
                            }
                        }
                    }
                    .padding(8)
                }
                Divider()
                ChannelStripView(strip: master, control: .fader, accent: accent)
                    .padding(8)
            }
        }
        .background(Color(white: 0.06))
    }

    private func sendsBanner(_ master: Strip) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
            Text("Faders are sends to **\(master.displayName)**")
            Spacer()
            Button("Back to Main") {
                mixer.selectedMix = .main
            }
            .font(.subheadline.weight(.semibold))
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(master.color.opacity(0.25))
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(mixer.status == .connected ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(mixer.mixerName.isEmpty ? mixer.host : mixer.mixerName)
                    .font(.headline)
                Text("\(mixer.model) · firmware \(mixer.firmware) · \(mixer.host)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if mixer.status != .connected {
                Label("Reconnecting…", systemImage: "wifi.exclamationmark")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.25), in: Capsule())
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button("Disconnect") {
                mixer.disconnect()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(white: 0.1))
    }
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
                ForEach(targets, id: \.self) { target in
                    chip(for: target)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(white: 0.09))
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
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? strip.color.opacity(0.35) : Color(white: 0.16), in: Capsule())
            .overlay(Capsule().stroke(isSelected ? strip.color : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
