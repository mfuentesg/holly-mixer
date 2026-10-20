import Observation
import SwiftUI
import UIKit

/// What a "Simple view" shows and allows: a short list of channels with one big MUTE button each, for someone who
/// should not see the rest of the mixer (for example the pastor and his microphones).
struct SimpleViewConfig: Codable, Equatable {
    /// Input channel numbers (1-16) shown, in this order.
    var channels: [Int] = []
    /// Also show a volume slider on each card. Off by default: mute and unmute only.
    var allowsVolume = false
    /// Hash of the PIN needed to go back to the full view; nil = holding the lock button and confirming is enough.
    var exitPinHash: String?
    init() {}
}

/// The draft being edited, and whether this device is locked in Simple view right now. Both are kept on the device.
@MainActor
@Observable
final class SimpleViewStore {
    static let shared = SimpleViewStore()
    private static let draftKey = "simpleViewDraft"
    private static let activeKey = "simpleViewActive"

    var draft: SimpleViewConfig {
        didSet { Self.save(draft, key: Self.draftKey) }
    }
    private(set) var active: SimpleViewConfig?

    private init() {
        draft = Self.load(Self.draftKey) ?? SimpleViewConfig()
        active = Self.load(Self.activeKey)
    }

    /// Locks this device in Simple view until the exit PIN (or a confirmation) is given.
    func start(_ config: SimpleViewConfig) {
        active = config
        Self.save(config, key: Self.activeKey)
    }

    func stop() {
        active = nil
        UserDefaults.standard.removeObject(forKey: Self.activeKey)
    }

    private static func load(_ key: String) -> SimpleViewConfig? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(SimpleViewConfig.self, from: $0) }
    }

    private static func save(_ config: SimpleViewConfig, key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(config), forKey: key)
    }
}

// MARK: - The view the pastor sees

struct SimpleView: View {
    @Environment(Mixer.self) private var mixer
    private let store = SimpleViewStore.shared
    @State private var confirmsExit = false
    @State private var asksPIN = false

    var body: some View {
        let config = store.active ?? SimpleViewConfig()
        let isReconnecting = mixer.status != .connected && !mixer.isDemo
        VStack(spacing: 0) {
            header
            if isReconnecting { ReconnectingBanner() }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                    ForEach(config.channels, id: \.self) { number in
                        if (1...16).contains(number) {
                            card(mixer.channels[number - 1], allowsVolume: config.allowsVolume)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
            .opacity(isReconnecting ? 0.4 : 1)
            .allowsHitTesting(!isReconnecting)
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.textPrimary)
        .textPageTypeSize()
        .confirmationDialog(L("Go back to the full view?"), isPresented: $confirmsExit, titleVisibility: .visible) {
            Button(L("Full view"), role: .destructive) { store.stop() }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("You will see every channel and every control."))
        }
        .sheet(isPresented: $asksPIN) {
            MusicianExitPINSheet(expectedHash: config.exitPinHash ?? "") {
                asksPIN = false
                store.stop()
            }
            .presentationDetents([.large])
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(L("Simple view")).scaledFont(22, .bold).lineLimit(1).minimumScaleFactor(0.7)
            ConnectionPill()
            Spacer(minLength: 8)
            HoldToExitButton(title: L("Full view")) {
                if store.active?.exitPinHash != nil { asksPIN = true } else { confirmsExit = true }
            }
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 64)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func card(_ strip: Strip, allowsVolume: Bool) -> some View {
        let muted = !strip.isOn
        let silencer = mixer.silencedBy(strip)
        let heard = !muted && silencer == nil
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3).fill(strip.color).frame(width: 6, height: 28)
                Text(strip.displayName)
                    .font(Theme.rounded(26, .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 6)
                Text(heard ? L("On") : (muted ? L("Muted") : L("Silenced by \(silencer ?? "")")))
                    .scaledFont(14, .bold)
                    .foregroundStyle(heard ? Theme.greenText : (muted ? Theme.muteBorder : Theme.amberText))
            }
            Button {
                mixer.toggleMute(strip)
            } label: {
                Text(muted ? L("TURN ON") : L("MUTE"))
                    .font(.system(size: 22, weight: .heavy))
                    .tracking(1)
                    .foregroundStyle(muted ? .white : Theme.textBright)
                    .frame(maxWidth: .infinity)
                    .frame(height: 88)
                    .background(muted ? Theme.mute : Theme.control, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18)
                        .stroke(muted ? Theme.muteBorder : Theme.borderStrong, lineWidth: 1.5))
                    .shadow(color: muted ? Theme.mute.opacity(0.45) : .clear, radius: 14)
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.impact(weight: .heavy), trigger: muted)
            .accessibilityLabel(muted ? L("Turn on \(strip.displayName)") : L("Mute \(strip.displayName)"))
            .accessibilityValue(heard ? L("on") : L("muted"))
            if allowsVolume {
                HStack(spacing: 10) {
                    PhoneHorizontalFader(
                        value: strip.fader, lineColor: strip.color, isMuted: muted,
                        capSize: CGSize(width: 40, height: 36), hitWidth: 56, trackHeight: 6, meterStrip: strip,
                        label: L("\(strip.displayName) fader"),
                        onTouchingChanged: { mixer.setTouching(strip, .fader, $0) },
                        onChange: { mixer.setLevel(strip, .fader, to: $0) }
                    )
                    .frame(height: 44)
                    Text(formatDecibels(strip.fader))
                        .font(Theme.mono(14, .bold))
                        .frame(width: 56, alignment: .trailing)
                }
            }
        }
        .padding(18)
        .background(muted ? Color(hex: 0x141012) : Theme.strip, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20)
            .stroke(muted ? Theme.mute.opacity(0.4) : Theme.border, lineWidth: 1))
    }
}

// MARK: - Settings: choose what he sees

struct SimpleViewSettingsView: View {
    @Environment(Mixer.self) private var mixer
    private let store = SimpleViewStore.shared
    @State private var pin = ""

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            ScreenTopBar(title: L("Simple view"),
                         subtitle: L("Let someone mute and unmute only the channels you choose."))
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    channelsCard(draft: $store.draft)
                    optionsCard(draft: $store.draft)
                    actionsCard
                }
                .padding(20)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.textPrimary)
        .textPageTypeSize()
        .onAppear {
            pin = ""
        }
    }

    // MARK: Cards

    private func channelsCard(draft: Binding<SimpleViewConfig>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("CHANNELS HE CAN SEE")).sectionLabelStyle()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ForEach(mixer.channels) { strip in
                    chip(strip, draft: draft)
                }
            }
            Text(L("He gets one big MUTE button for each. Nothing else of the mixer is shown."))
                .scaledFont(12)
                .foregroundStyle(Theme.textTertiary)
        }
        .card()
    }

    private func chip(_ strip: Strip, draft: Binding<SimpleViewConfig>) -> some View {
        let number = strip.channelNumber ?? 0
        let isOn = draft.wrappedValue.channels.contains(number)
        return Button {
            if isOn { draft.wrappedValue.channels.removeAll { $0 == number } }
            else { draft.wrappedValue.channels.append(number); draft.wrappedValue.channels.sort() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Theme.accent : Theme.textDim)
                Circle().fill(strip.color).frame(width: 8, height: 8)
                Text(strip.displayName).scaledFont(13, .semibold).lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isOn ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(isOn ? Theme.controlSelected : Theme.control, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(isOn ? Theme.accent.opacity(0.8) : Color.white.opacity(0.08), lineWidth: isOn ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(strip.displayName)
        .accessibilityValue(isOn ? L("yes") : L("no"))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func optionsCard(draft: Binding<SimpleViewConfig>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: draft.allowsVolume) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Also let him change the volume")).scaledFont(16, .semibold)
                    Text(L("Off: only mute and unmute."))
                        .scaledFont(12)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Divider().overlay(Theme.border)
            VStack(alignment: .leading, spacing: 8) {
                Text(L("PIN TO RETURN TO THE FULL VIEW")).sectionLabelStyle()
                TextField(L("4 digits (optional)"), text: $pin)
                    .keyboardType(.numberPad)
                    .font(Theme.mono(18, .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 48)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
                    .onChange(of: pin) { _, text in
                        let digits = String(text.filter(\.isNumber).prefix(ServicePINPad.pinLength))
                        if digits != text { pin = digits }
                        draft.wrappedValue.exitPinHash = digits.count == ServicePINPad.pinLength
                            ? MonitorPairing.hash(ofPIN: digits) : nil
                    }
                Text(draft.wrappedValue.exitPinHash == nil
                     ? L("Without a PIN, holding the lock button and confirming is enough.")
                     : L("PIN set. Only you should know it."))
                    .scaledFont(12)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .card()
    }

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("ON THIS DEVICE")).sectionLabelStyle()
            Button {
                store.start(store.draft)
                mixer.presentedScreen = nil
            } label: {
                Text(L("Start Simple view on this device"))
                    .scaledFont(16, .bold)
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(store.draft.channels.isEmpty)
            .opacity(store.draft.channels.isEmpty ? 0.4 : 1)
            Text(L("This device then shows only those channels until the PIN is entered (or the lock button is held and confirmed)."))
                .scaledFont(12)
                .foregroundStyle(Theme.textTertiary)
        }
        .card()
    }
}

private extension View {
    func card() -> some View {
        padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border, lineWidth: 1))
    }
}
