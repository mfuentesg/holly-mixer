import CryptoKit
import SwiftUI

/// Which mixer, bus and channel a musician's iPhone is locked to.
struct MonitorPairing: Codable, Equatable {
    /// Mixer address, or "demo" for the built-in demo mixer.
    let host: String
    /// Bus 1-6 the musician hears.
    let bus: Int
    /// The musician's own input channel, 1-16.
    let me: Int
    /// How this iPhone may change its return: nil or "locked", "pin" or "free". The mixer has no user accounts, so
    /// this lives in the app only.
    var lock: String?
    /// Hash of the PIN needed to leave musician mode, or nil when leaving only asks for a confirmation.
    var exitPinHash: String?

    /// A short hash, so the stored pairing never carries the PIN itself.
    static func hash(ofPIN pin: String) -> String {
        SHA256.hash(data: Data(("holly-mixer-exit:" + pin).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static let storageKey = "monitorPairing"

    init?(host: String, bus: Int, me: Int, lock: String? = nil, exitPinHash: String? = nil) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidHost(trimmed), (1...6).contains(bus), (1...16).contains(me) else { return nil }
        self.host = trimmed
        self.bus = bus
        self.me = me
        self.lock = lock == "free" ? lock : nil
        self.exitPinHash = exitPinHash.flatMap { $0.count == 16 && $0.allSatisfy(\.isHexDigit) ? $0 : nil }
    }

    /// How this iPhone may change its return. Only "free" is honoured; anything else is locked.
    var switching: MonitorSwitching {
        let mode = MonitorSwitching(rawValue: lock ?? "") ?? .locked
        return MonitorSwitching.available.contains(mode) ? mode : .locked
    }

    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_:"))
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    var isDemo: Bool { host == "demo" }

    var json: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// Reads a pairing stored with `json`; nil for empty or corrupt text.
    static func decode(_ json: String) -> MonitorPairing? {
        guard let data = json.data(using: .utf8), !data.isEmpty,
              let stored = try? JSONDecoder().decode(MonitorPairing.self, from: data) else { return nil }
        return MonitorPairing(host: stored.host, bus: stored.bus, me: stored.me, lock: stored.lock,
                              exitPinHash: stored.exitPinHash)
    }
}

/// Whether and how an iPhone in musician mode may change which return (bus) it controls.
enum MonitorSwitching: String, CaseIterable, Identifiable {
    /// Fixed to one bus; leaving needs a long press (and re-pairing to change).
    case locked
    /// Changing needs the Service Mode PIN.
    /// Changing is one tap, for the sound lead.
    case free

    var id: String { rawValue }

    static var available: [MonitorSwitching] { allCases }

    var title: String {
        switch self {
        case .locked: return L("Locked")
        case .free: return L("Free")
        }
    }
}

/// Sheet on the iPhone for joining as a musician: the mixer address, which monitor mix and which channel is yours.
struct MonitorSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onPair: (MonitorPairing) -> Void

    @State private var hostText = ""
    @State private var bus = 1
    @State private var me = 1
    @State private var pin = ""
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Set up as musician"))
                    .scaledFont(20, .bold)
                Spacer()
                Button("Cancel") { dismiss() }
                    .scaledFont(16, .semibold)
                    .foregroundStyle(Theme.accentText)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L("This phone will only control your own monitor mix. Ask the sound lead for the address, the monitor and your channel."))
                        .scaledFont(14)
                        .foregroundStyle(Theme.textSecondary)
                    TextField("Mixer address (e.g. 192.168.1.2)", text: $hostText)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(Theme.mono(16, .regular))
                        .padding(.horizontal, 12)
                        .frame(height: 48)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                    Stepper(L("Monitor \(bus)"), value: $bus, in: 1...6)
                        .frame(minHeight: 44)
                    Stepper("My channel \(me)", value: $me, in: 1...16)
                        .frame(minHeight: 44)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("EXIT PIN (OPTIONAL)")).sectionLabelStyle()
                        TextField(L("4 digits"), text: $pin)
                            .keyboardType(.numberPad)
                            .font(Theme.mono(18, .semibold))
                            .padding(.horizontal, 12)
                            .frame(height: 48)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                            .onChange(of: pin) { _, text in
                                let digits = String(text.filter(\.isNumber).prefix(4))
                                if digits != text { pin = digits }
                            }
                        Text(L("With a PIN, the musician must type it to leave musician mode. Without one, holding Exit and confirming is enough."))
                            .scaledFont(12)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    if let message {
                        Text(message)
                            .scaledFont(13, .semibold)
                            .foregroundStyle(Theme.meterRed)
                    }
                    Button {
                        join()
                    } label: {
                        Text("Join")
                            .scaledFont(16, .bold)
                            .foregroundStyle(Theme.onAccent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.textPrimary)
    }

    private func join() {
        let hash = pin.count == 4 ? MonitorPairing.hash(ofPIN: pin) : nil
        if let pairing = MonitorPairing(host: hostText, bus: bus, me: me, exitPinHash: hash) {
            onPair(pairing)
        } else {
            message = L("Enter the mixer's address, like 192.168.1.2.")
        }
    }
}
