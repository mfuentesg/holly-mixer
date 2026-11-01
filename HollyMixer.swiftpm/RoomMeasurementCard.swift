import SwiftUI

/// "Measure the room" in the Main's EQ assistant: the device is put where the audience sits, with pink noise
/// through the PA for the spectrum and a clap for the reverberation. Only numbers are kept.
@MainActor
struct RoomMeasurementCard: View {
    @Binding var room: RoomMeasurement?
    /// Called with the measured spectrum when the user asks for a main EQ proposal.
    let onPropose: ([Float]) -> Void

    @State private var meter = RoomMeter()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MEASURE THE ROOM").sectionLabelStyle()
            Text("Put the device where the audience sits (for example row 6) and stay quiet. Play pink noise through the PA for the spectrum, or clap once for the reverberation.")
                .scaledFont(13).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if meter.isMeasuring {
                ProgressView(value: meter.progress).tint(Theme.accent)
                if meter.kind == .spectrum, !meter.live.isEmpty {
                    EQSpectrumPlot(bins: meter.live).frame(height: 110)
                }
                Text("Level: \(Int(meter.level.rounded())) dB").font(Theme.mono(12, .regular))
                    .foregroundStyle(Theme.textTertiary)
                actionButton(L("Stop"), icon: "stop.fill", prominent: false) { meter.cancel() }
            } else {
                HStack(spacing: 10) {
                    actionButton(L("Pink noise · 20 s"), icon: "waveform", prominent: true) { meter.start(.spectrum) }
                    actionButton(L("Clap · 8 s"), icon: "hands.clap", prominent: false) { meter.start(.reverb) }
                }
            }

            if case .failed(let message) = meter.state {
                Text(message).scaledFont(13).foregroundStyle(Theme.amberText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let room, !meter.isMeasuring {
                results(room)
            }

            Text("Uses the microphone only while measuring. No audio is saved or sent: only the spectrum and the reverberation time are kept. The microphone is not flat, so trust big differences more than small ones.")
                .scaledFont(11).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .detailCard()
        .onDisappear { meter.cancel() }
        .onChange(of: meter.result) { _, new in
            if let new { room = new }
        }
    }

    private func results(_ room: RoomMeasurement) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let date = room.date {
                Text("Last measurement: \(date.hollyMixer(date: .abbreviated, time: .shortened))")
                    .scaledFont(12).foregroundStyle(Theme.textTertiary)
            }
            if let rt60 = room.rt60 {
                Text("Reverberation: \(ParamFormat.plain(rt60)) s")
                    .scaledFont(14, .semibold).foregroundStyle(Theme.textBright)
                Text(reverbNote(rt60)).scaledFont(12).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let bins = room.bins {
                EQSpectrumPlot(bins: bins).frame(height: 110)
                let findings = EQAdvisor.roomFindings(bins)
                if findings.isEmpty {
                    Text("The PA and room look reasonably even between 63 Hz and 12 kHz.")
                        .scaledFont(13).foregroundStyle(Theme.textSecondary)
                }
                ForEach(findings, id: \.self) { text in
                    Text("• " + text).scaledFont(13).foregroundStyle(Theme.textBright)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actionButton(L("Suggest a main EQ from the room"), icon: "sparkles", prominent: false) {
                    onPropose(bins)
                }
            }
        }
    }

    private func reverbNote(_ seconds: Float) -> String {
        if seconds >= 2 { return L("Long: speech loses clarity. Keep low-mids tight and avoid boosting highs.") }
        if seconds >= 1.2 { return L("Moderate: usual for a church. Watch the low-mids.") }
        return L("Short: a dry room.")
    }

    private func actionButton(_ title: String, icon: String, prominent: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .scaledFont(15, .semibold)
                .foregroundStyle(prominent ? Theme.onAccent : Theme.textControl)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(prominent ? Theme.accent : Theme.control, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
