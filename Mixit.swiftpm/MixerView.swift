import SwiftUI

struct MixerView: View {
    @Environment(Mixer.self) private var mixer

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(mixer.channels) { strip in
                            ChannelStripView(strip: strip)
                        }
                    }
                    .padding(8)
                }
                Divider()
                ChannelStripView(strip: mixer.main)
                    .padding(8)
            }
        }
        .background(Color(white: 0.06))
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
