import SwiftUI

/// Musician monitor mode: the iPhone is locked to one bus ("My mix") and can only change
/// what that musician hears. No mix selector, no mutes, no other pages.
struct PhoneMonitorView: View {
    @Environment(Mixer.self) private var mixer
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let pairing: MonitorPairing
    var onSwitch: (MonitorPairing) -> Void = { _ in }
    var onExit: () -> Void

    @State private var showsAllInputs = false
    @State private var confirmsExit = false
    @State private var asksPIN = false
    @State private var asksExitPIN = false
    @State private var picksReturn = false

    private var busMaster: Strip { mixer.master(for: .bus(pairing.bus)) }
    private var sendControl: LevelControl { .send(pairing.bus - 1) }
    private var meStrip: Strip { mixer.channels[min(max(pairing.me, 1), 16) - 1] }

    /// Inputs other than the musician's own, hiding unused (unnamed, silent) ones unless asked.
    private var otherInputs: [Strip] {
        mixer.inputs.filter { strip in
            guard strip.kind != meStrip.kind, strip.hasControl(sendControl) else { return false }
            return showsAllInputs || strip.isNamed || strip.level(sendControl) > 0
        }
    }

    var body: some View {
        let isReconnecting = mixer.status != .connected && !mixer.isDemo
        VStack(spacing: 0) {
            header
            if verticalSizeClass == .compact {
                ScrollView {
                    VStack(spacing: 6) {
                        meCard
                        inputRows
                    }
                    .padding(12)
                }
            } else {
                meCard.padding(.horizontal, 12)
                ScrollView {
                    inputRows.padding(12)
                }
            }
            footer
        }
        .opacity(isReconnecting ? 0.5 : 1)
        .overlay(alignment: .top) {
            if isReconnecting {
                ReconnectingBanner()
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.textPrimary)
        .sheet(isPresented: $asksPIN) {
            ServicePINSheet(store: ServiceLayoutStore.shared) {
                asksPIN = false
                picksReturn = true
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $asksExitPIN) {
            MusicianExitPINSheet(expectedHash: pairing.exitPinHash ?? "") {
                asksExitPIN = false
                onExit()
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $picksReturn) {
            ReturnPickerSheet(pairing: pairing) { newPairing in
                picksReturn = false
                onSwitch(newPairing)
            }
            .environment(mixer)
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog("Leave musician mode?", isPresented: $confirmsExit, titleVisibility: .visible) {
            Button("Exit musician mode", role: .destructive) {
                if pairing.exitPinHash != nil { asksExitPIN = true } else { onExit() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This iPhone will stop being locked to \(busMaster.displayName).")
        }
    }

    // MARK: - Header and footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("MY MIX").sectionLabelStyle()
                Spacer()
                if pairing.switching == .locked {
                    Label("Bus \(pairing.bus) only", systemImage: "lock.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Theme.card, in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
                } else {
                    Button {
                        if pairing.switching == .pin { asksPIN = true } else { picksReturn = true }
                    } label: {
                        Label("Return", systemImage: pairing.switching == .pin ? "lock.open" : "arrow.left.arrow.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accentText)
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .background(Theme.accent.opacity(0.14), in: Capsule())
                            .overlay(Capsule().stroke(Theme.accent.opacity(0.45), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                HoldToExitButton { confirmsExit = true }
            }
            HStack(spacing: 10) {
                Circle().fill(busMaster.color).frame(width: 12, height: 12)
                Text(busMaster.displayName)
                    .font(Theme.rounded(30, .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        let level = busMaster.fader
        return VStack(spacing: 4) {
            HStack {
                Text("IN MY EARS").sectionLabelStyle()
                Spacer()
                Text(formatDecibels(level) + L(" dB"))
                    .font(Theme.mono(18, .bold))
            }
            PhoneHorizontalFader(
                value: level, lineColor: busMaster.color, capSize: CGSize(width: 40, height: 32),
                trackHeight: 6, meterStrip: busMaster, label: L("\(busMaster.displayName) master"),
                onTouchingChanged: { mixer.setTouching(busMaster, .fader, $0) },
                onChange: { mixer.setLevel(busMaster, .fader, to: $0) }
            )
            .frame(height: 48)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    // MARK: - Faders

    /// The musician's own channel, pinned above the others.
    private var meCard: some View {
        let strip = meStrip
        let level = strip.level(sendControl)
        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("ME")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(busMaster.onColor)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(busMaster.color, in: RoundedRectangle(cornerRadius: 6))
                Text(strip.displayName)
                    .font(Theme.rounded(18, .heavy))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(formatDecibels(level))
                    .font(Theme.mono(16, .bold))
            }
            PhoneHorizontalFader(
                value: level, lineColor: busMaster.color, capSize: CGSize(width: 44, height: 40),
                trackHeight: 6, meterStrip: strip, label: L("\(strip.displayName), me, in my mix"),
                onTouchingChanged: { mixer.setTouching(strip, sendControl, $0) },
                onChange: { mixer.setLevel(strip, sendControl, to: $0) }
            )
            .frame(height: 48)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(busMaster.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(busMaster.color.opacity(0.6), lineWidth: 1.5))
    }

    private var inputRows: some View {
        VStack(spacing: 6) {
            ForEach(otherInputs) { strip in
                sendRow(strip)
            }
            Button {
                showsAllInputs.toggle()
            } label: {
                Text(showsAllInputs ? L("Hide unused inputs") : L("Show all inputs"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.plain)
        }
    }

    private func sendRow(_ strip: Strip) -> some View {
        let level = strip.level(sendControl)
        return VStack(spacing: 2) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(strip.color)
                    .frame(width: 4, height: 14)
                Text(strip.displayName)
                    .font(Theme.rounded(16))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(formatDecibels(level))
                    .font(Theme.mono(14, .bold))
                    .foregroundStyle(Theme.textBright)
            }
            PhoneHorizontalFader(
                value: level, lineColor: busMaster.color, capSize: CGSize(width: 40, height: 32),
                meterStrip: strip, label: L("\(strip.displayName) in my mix"),
                onTouchingChanged: { mixer.setTouching(strip, sendControl, $0) },
                onChange: { mixer.setLevel(strip, sendControl, to: $0) }
            )
            .frame(height: 40)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}

/// Small "Exit" control that must be held for 2 seconds, so it can't be hit by accident.
struct HoldToExitButton: View {
    var onConfirm: () -> Void
    @State private var progress: CGFloat = 0

    var body: some View {
        Text("Hold to exit")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background {
                GeometryReader { geometry in
                    Rectangle()
                        .fill(Theme.accent.opacity(0.4))
                        .frame(width: geometry.size.width * progress)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .clipShape(Capsule())
            }
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 2, maximumDistance: 40) {
                progress = 0
                onConfirm()
            } onPressingChanged: { isPressing in
                withAnimation(isPressing ? .linear(duration: 2) : .easeOut(duration: 0.15)) {
                    progress = isPressing ? 1 : 0
                }
            }
            .accessibilityLabel("Exit musician mode")
            .accessibilityHint("Touch and hold for two seconds")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, onConfirm)
    }
}

/// The six returns (buses), with the ones that look in use first. A return counts as active when it has a name or
/// a colour of its own, or someone sends to it, and its master is up and not muted.
struct ReturnPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Mixer.self) private var mixer
    let pairing: MonitorPairing
    var onPick: (MonitorPairing) -> Void

    @State private var showsUnused = false

    private var numbers: [Int] {
        let all = Array(1...6)
        let visible = all.filter { showsUnused || mixer.isReturnActive($0) || $0 == pairing.bus }
        return visible.sorted { (mixer.isReturnActive($0) ? 0 : 1, $0) < (mixer.isReturnActive($1) ? 0 : 1, $1) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(numbers, id: \.self) { number in
                        let master = mixer.master(for: .bus(number))
                        Button {
                            if let next = MonitorPairing(host: pairing.host, bus: number, me: pairing.me, lock: pairing.lock) {
                                onPick(next)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 2).fill(master.color).frame(width: 4, height: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(master.displayName).font(Theme.rounded(17))
                                    Text(mixer.isReturnActive(number) ? L("In use") : L("Unused"))
                                        .font(.system(size: 12))
                                        .foregroundStyle(mixer.isReturnActive(number) ? Theme.greenText : Theme.textTertiary)
                                }
                                Spacer()
                                Text("Bus \(number)").font(Theme.mono(12, .regular)).foregroundStyle(Theme.textTertiary)
                                if number == pairing.bus {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accentText)
                                }
                            }
                            .frame(minHeight: 48)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.card)
                    }
                } footer: {
                    Text("Only the return changes. Your own channel stays the same.")
                }
                Section {
                    Toggle("Show unused returns", isOn: $showsUnused)
                        .listRowBackground(Theme.card)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Change return")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}
