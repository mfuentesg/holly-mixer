import SwiftUI

/// The EQ assistant: checks on the EQ in force, a recording of the strip's spectrum, and a proposed EQ from rules or
/// from Claude. Nothing reaches the mixer until the user taps Apply; Apply saves a safety copy and is one Undo step.
@MainActor
struct EQAssistantSheet: View {
    @Environment(Mixer.self) private var mixer
    @Environment(\.dismiss) private var dismiss
    let strip: Strip

    @State private var recorder = EQSpectrumRecorder()
    @State private var role = EQRole.other
    @State private var recording: EQRecording?
    @State private var proposal: EQProposal?
    @State private var summary = ""
    @State private var goal = ""
    @State private var apiKey = ""
    @State private var isAsking = false
    @State private var error: String?
    @State private var confirmsApply = false
    @State private var applied = false
    @AppStorage("eqAssistantUsesClaude") private var usesClaude = false

    var body: some View {
        let snapshot = EQModel.snapshot(mixer, strip, role: role)
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 12) {
                    roleCard
                    checksCard(snapshot)
                    recordCard
                    suggestCard(snapshot)
                    if let proposal {
                        proposalCard(snapshot, proposal)
                    }
                }
                .padding(16)
            }
        }
        .background(Theme.background)
        .task {
            role = EQRoleStore.role(base: strip.base, name: strip.name)
            recording = EQRecordingStore.latest(label: EQRecording.label(for: strip))
            apiKey = APIKeyStore.load() ?? ""
        }
        .onDisappear { recorder.cancel() }
        .onChange(of: recorder.state) { _, state in
            if state == .finished {
                recording = recorder.result
                proposal = nil
            }
        }
        .onChange(of: role) { _, new in EQRoleStore.set(new, base: strip.base) }
        .onChange(of: apiKey) { _, new in APIKeyStore.save(new) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("EQ assistant").font(Theme.rounded(20)).foregroundStyle(Theme.textPrimary)
                Text(strip.displayName).scaledFont(13).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Button("Close") { dismiss() }
                .scaledFont(15, .semibold)
                .foregroundStyle(Theme.accentText)
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: Cards

    private var roleCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("This strip carries").scaledFont(14, .semibold).foregroundStyle(Theme.textPrimary)
                Text("The checks and suggestions depend on it.").scaledFont(12).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Picker("Role", selection: $role) {
                ForEach(EQRole.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .tint(Theme.accentText)
        }
        .detailCard()
    }

    private func checksCard(_ snapshot: EQSnapshot) -> some View {
        let hints = EQAdvisor.hints(snapshot)
        return VStack(alignment: .leading, spacing: 8) {
            Text("CHECKS ON THE CURRENT EQ").sectionLabelStyle()
            if hints.isEmpty {
                Text("Nothing stands out.").scaledFont(14).foregroundStyle(Theme.textSecondary)
            }
            ForEach(hints) { hint in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(color(hint.level)).frame(width: 8, height: 8).padding(.top, 6)
                    Text(hint.text).scaledFont(14).foregroundStyle(Theme.textBright)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Rules of thumb from the numbers alone. Listen before changing anything.")
                .scaledFont(12).foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .detailCard()
    }

    private func color(_ level: EQHint.Level) -> Color {
        switch level {
        case .strong: return Theme.meterRed
        case .warning: return Theme.meterAmber
        case .note: return Theme.textTertiary
        }
    }

    private var recordCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RECORD THE SPECTRUM").sectionLabelStyle()
            Text("The mixer's RTA shows one source at a time: the one chosen in X-AIR Edit. Set it to this strip, then record while it is being used.")
                .scaledFont(13).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if mixer.isDemo {
                Text("Demo mixer: a sample spectrum is used.").scaledFont(12).foregroundStyle(Theme.demoText)
            }
            if recorder.state == .recording {
                ProgressView(value: min(recorder.elapsed / recorder.duration, 1)).tint(Theme.accent)
            } else {
                Picker("Duration", selection: $recorder.duration) {
                    Text("30 s").tag(30.0)
                    Text("60 s").tag(60.0)
                }
                .pickerStyle(.segmented)
            }
            let bins: [Float] = recorder.state == .recording ? recorder.live : (recording?.rta.meanDb ?? [])
            if !bins.isEmpty {
                EQSpectrumPlot(bins: bins).frame(height: 110)
            }
            actionButton(recorder.state == .recording ? L("Stop") : L("Record"),
                         icon: recorder.state == .recording ? "stop.fill" : "record.circle",
                         prominent: recorder.state != .recording) {
                if recorder.state == .recording {
                    recorder.stop()
                } else {
                    recorder.start(mixer: mixer, strip: strip)
                }
            }
            if recorder.state == .recording {
                Text("\(recorder.activeFrames) frames with signal").scaledFont(12).foregroundStyle(Theme.textTertiary)
            }
            if let recording, recorder.state != .recording {
                recordingSummary(recording)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .detailCard()
    }

    private func recordingSummary(_ recording: EQRecording) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let date = recording.date {
                Text("Last recording: \(date.hollyMixer(date: .abbreviated, time: .shortened))")
                    .scaledFont(12).foregroundStyle(Theme.textTertiary)
            }
            if !recording.hasSignal {
                Text("Very little signal was recorded: nothing reliable to say. Is the RTA source this strip, and is it playing?")
                    .scaledFont(13).foregroundStyle(Theme.amberText)
            } else {
                let findings = recording.rta.findings()
                if findings.isEmpty {
                    Text("The spectrum shows no obvious problem.").scaledFont(13).foregroundStyle(Theme.textSecondary)
                }
                ForEach(findings) { finding in
                    Text("• " + finding.text).scaledFont(13).foregroundStyle(Theme.textBright)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !recording.meta.rtaAxis.verified {
                    Text("The RTA's frequency scale is assumed (20 Hz–20 kHz, logarithmic) and not yet checked on this mixer.")
                        .scaledFont(11).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private func suggestCard(_ snapshot: EQSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SUGGEST AN EQ").sectionLabelStyle()
            TextField("What do you want? (optional, e.g. clearer voice)", text: $goal)
                .scaledFont(14)
                .padding(10)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(Theme.textPrimary)
            actionButton(L("Suggest from rules"), icon: "list.bullet.clipboard", prominent: false) {
                error = nil
                applied = false
                summary = ""
                let findings = (recording?.hasSignal == true) ? (recording?.rta.findings() ?? []) : []
                let result = EQAdvisor.rulesProposal(snapshot, findings: findings)
                proposal = result
                if result.isEmpty { error = L("The rules found nothing to change. Record the spectrum for more.") }
            }
            Toggle(isOn: $usesClaude) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask Claude").scaledFont(14, .semibold).foregroundStyle(Theme.textPrimary)
                    Text("Sends this strip's name, its EQ and the recorded spectrum over the internet. Never the mixer's address or a backup.")
                        .scaledFont(12).foregroundStyle(Theme.textTertiary)
                }
            }
            if usesClaude {
                SecureField("Claude API key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .scaledFont(14)
                    .padding(10)
                    .background(Theme.control, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(Theme.textPrimary)
                Text("Kept in this device's Keychain.").scaledFont(11).foregroundStyle(Theme.textTertiary)
                DisclosureGroup {
                    Text(EQClaude.payload(snapshot, spectrum: recording?.hasSignal == true ? recording?.rta : nil,
                                          findings: recording?.rta.findings() ?? [], goal: goal))
                        .font(Theme.mono(11, .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("See exactly what is sent").scaledFont(13).foregroundStyle(Theme.accentText)
                }
                actionButton(isAsking ? L("Asking…") : L("Ask Claude"), icon: "sparkles", prominent: true) {
                    ask(snapshot)
                }
                .disabled(isAsking || apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error {
                Text(error).scaledFont(13).foregroundStyle(Theme.amberText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .detailCard()
    }

    private func proposalCard(_ snapshot: EQSnapshot, _ proposal: EQProposal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(proposal.source == .claude ? L("PROPOSAL FROM CLAUDE") : L("PROPOSAL FROM THE RULES"))
                .sectionLabelStyle()
            if !summary.isEmpty {
                Text(summary).scaledFont(14).foregroundStyle(Theme.textBright)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if proposal.isEmpty {
                Text("No change proposed.").scaledFont(14).foregroundStyle(Theme.textSecondary)
            } else {
                EQCompareGraph(
                    before: EQFilterSet(bands: snapshot.eqOn ? snapshot.bands : [],
                                        lowCutFrequency: snapshot.lowCutOn == true ? snapshot.lowCutHz : nil),
                    after: EQFilterSet(bands: EQAdvisor.bandsAfter(snapshot, proposal),
                                       lowCutFrequency: proposal.lowCutHz
                                           ?? (snapshot.lowCutOn == true ? snapshot.lowCutHz : nil)))
                    .frame(height: 120)
                HStack(spacing: 16) {
                    legend(L("Now"), Theme.textDim)
                    legend(L("Proposed"), Theme.accent)
                }
            }
            if let cut = proposal.lowCutHz {
                let was = snapshot.lowCutOn == true ? "\(ParamFormat.frequency(snapshot.lowCutHz)) Hz" : L("off")
                changeRow(L("Low cut"), "\(was) → \(ParamFormat.frequency(cut)) Hz", why: "")
            }
            ForEach(proposal.bands) { band in
                let old = snapshot.bands.indices.contains(band.band - 1) ? describe(snapshot.bands[band.band - 1]) : "?"
                changeRow(L("Band \(band.band)"), "\(describe(EQBand(type: band.type, frequency: band.frequency, gain: band.gain, q: band.q))) (\(L("now")): \(old))",
                          why: band.why)
            }
            if !proposal.reasoning.isEmpty {
                Text(proposal.reasoning).scaledFont(13).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(proposal.notes, id: \.self) { note in
                Text("• " + note).scaledFont(12).foregroundStyle(Theme.amberText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if applied {
                Text("Applied. Use Undo to go back in one step; a safety copy was saved in Backups.")
                    .scaledFont(13).foregroundStyle(Theme.greenText)
            } else if !proposal.isEmpty {
                HStack(spacing: 10) {
                    actionButton(L("Apply to the mixer"), icon: "checkmark", prominent: true) { confirmsApply = true }
                    actionButton(L("Discard"), icon: "xmark", prominent: false) { self.proposal = nil }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .detailCard(highlighted: true)
        .confirmationDialog("Apply this EQ to \(strip.displayName)?", isPresented: $confirmsApply,
                            titleVisibility: .visible) {
            Button("Apply") {
                EQAdvisor.apply(proposal, strip: strip, mixer: mixer)
                applied = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A safety copy of the mixer's settings is saved first, and Undo reverts it in one step.")
        }
    }

    // MARK: Pieces

    private func describe(_ band: EQBand) -> String {
        var text = "\(band.type.name) \(ParamFormat.frequency(band.frequency)) Hz"
        if band.type.hasGain { text += " \(ParamFormat.signed(band.gain)) dB" }
        if band.type.hasQ { text += " Q \(ParamFormat.plain(band.q))" }
        return text
    }

    private func changeRow(_ title: String, _ detail: String, why: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).scaledFont(13, .bold).foregroundStyle(Theme.textPrimary)
                Text(detail).font(Theme.mono(12, .regular)).foregroundStyle(Theme.textControl)
            }
            if !why.isEmpty {
                Text(why).scaledFont(12).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 18, height: 3)
            Text(title).scaledFont(12).foregroundStyle(Theme.textTertiary)
        }
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

    private func ask(_ snapshot: EQSnapshot) {
        error = nil
        applied = false
        isAsking = true
        let spectrum = recording?.hasSignal == true ? recording?.rta : nil
        let payload = EQClaude.payload(snapshot, spectrum: spectrum,
                                       findings: spectrum?.findings() ?? [], goal: goal)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let (result, text) = try await EQClaude.ask(payload: payload, apiKey: key, snapshot: snapshot)
                proposal = result
                summary = text
            } catch {
                self.error = error.localizedDescription
            }
            isAsking = false
        }
    }
}

// MARK: - Drawing

/// The recorded spectrum on a log frequency axis. The vertical scale shows the 60 dB below the loudest bin.
private struct EQSpectrumPlot: View {
    let bins: [Float]

    var body: some View {
        Canvas { context, size in
            guard bins.count > 1, let top = bins.max() else { return }
            let floor = top - 60
            var line = Path()
            for (index, value) in bins.enumerated() {
                let x = size.width * CGFloat((Double(index) + 0.5) / Double(bins.count))
                let fraction = CGFloat(min(max((value - floor) / 60, 0), 1))
                let point = CGPoint(x: x, y: size.height * (1 - fraction))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(Theme.accent.opacity(0.15)))
            context.stroke(line, with: .color(Theme.accent), lineWidth: 1.5)
            for mark in [100.0, 1000.0, 10000.0] {
                let x = size.width * CGFloat(EQScale.position(of: mark))
                var grid = Path()
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 1)
            }
        }
        .background(Color(hex: 0x0D0E12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Recorded spectrum")
    }
}

/// The EQ curve now and as proposed, ±15 dB.
private struct EQCompareGraph: View {
    let before: EQFilterSet
    let after: EQFilterSet

    var body: some View {
        Canvas { context, size in
            func path(_ values: [Double]) -> Path {
                var path = Path()
                for (index, db) in values.enumerated() {
                    let x = size.width * CGFloat(Double(index) / Double(max(values.count - 1, 1)))
                    let y = size.height / 2 - CGFloat(min(max(db, -15), 15) / 15) * size.height / 2
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                return path
            }
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: size.height / 2))
            zero.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(zero, with: .color(.white.opacity(0.18)), lineWidth: 1)
            context.stroke(path(before.curve(count: 160)), with: .color(Theme.textDim), lineWidth: 2)
            context.stroke(path(after.curve(count: 160)), with: .color(Theme.accent), lineWidth: 2.5)
        }
        .background(Color(hex: 0x0D0E12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("EQ now and as proposed")
    }
}
