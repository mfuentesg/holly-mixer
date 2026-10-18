import SwiftUI

struct ConnectView: View {
    @Environment(Mixer.self) private var mixer
    @Binding var host: String

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Image(systemName: "slider.vertical.3")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("Mixit")
                    .font(.largeTitle.bold())
                Text("Remote for Behringer X AIR mixers")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Mixer IP address")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("192.168.1.2", text: $host)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3.monospacedDigit())
                    .disabled(isBusy)
            }
            .frame(maxWidth: 320)

            Button(isBusy ? "Cancel" : "Connect") {
                if isBusy {
                    mixer.disconnect()
                } else {
                    mixer.connect(host: host.trimmingCharacters(in: .whitespaces))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!isBusy && host.isEmpty)

            Button {
                mixer.startDemo()
            } label: {
                Label("Try the demo mixer", systemImage: "play.circle")
            }
            .buttonStyle(.bordered)

            statusView
                .frame(maxWidth: 360)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.08))
    }

    private var isBusy: Bool {
        mixer.status != .disconnected
    }

    @ViewBuilder
    private var statusView: some View {
        switch mixer.status {
        case .disconnected:
            Text("The mixer and this device must be on the same network.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .connecting:
            HStack(spacing: 8) {
                ProgressView()
                Text("Looking for the mixer at \(mixer.host)…")
            }
            .foregroundStyle(.secondary)
        case .waitingForNetwork(let reason):
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for the network…")
                }
                Text("If iOS asked for Local Network access, tap Allow. You can change it later in Settings › Privacy & Security › Local Network.")
                    .font(.footnote)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}
