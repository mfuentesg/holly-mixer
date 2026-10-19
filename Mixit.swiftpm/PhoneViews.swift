import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// iPhone layout (PhoneMixer.dc.html and PhoneMonitor.dc.html): the paired musician's "My mix",
/// otherwise the mixer, as a list of horizontal faders in portrait and the iPad mixer in landscape.
struct PhoneRootView: View {
    @Environment(Mixer.self) private var mixer
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage(MonitorPairing.storageKey) private var pairingJSON = ""
    @AppStorage("mixerHost") private var mixerHost = "192.168.1.2"

    var body: some View {
        if let pairing = MonitorPairing.decode(pairingJSON) {
            PhoneMonitorView(pairing: pairing, onSwitch: { pairingJSON = $0.json }) { pairingJSON = "" }
        } else if verticalSizeClass == .compact {
            MixerView()
        } else {
            PhoneMixerView(onPair: join)
        }
    }

    /// Remembers the pairing and connects to its mixer.
    private func join(_ pairing: MonitorPairing) {
        pairingJSON = pairing.json
        if pairing.isDemo {
            if !mixer.isDemo { mixer.startDemo() }
        } else {
            mixerHost = pairing.host
            if mixer.isDemo || mixer.host != pairing.host { mixer.connect(host: pairing.host) }
        }
    }
}

/// Page on the iPad that shows a QR code for pairing a musician's iPhone to one bus.
struct MonitorPairingView: View {
    @Environment(Mixer.self) private var mixer
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var bus = 1
    @State private var me = 1
    @State private var lock = MonitorSwitching.locked

    private var pairing: MonitorPairing? {
        MonitorPairing(host: mixer.isDemo ? "demo" : mixer.host, bus: bus, me: me,
                       lock: lock == .locked ? nil : lock.rawValue)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenTopBar(title: L("Pair a musician's iPhone"),
                         subtitle: L("Locks the iPhone to one bus: the musician only mixes their own monitor."))
            ScrollView {
                if sizeClass == .regular {
                    HStack(alignment: .top, spacing: 32) {
                        pickers.frame(maxWidth: .infinity)
                        codeCard.frame(maxWidth: 420)
                    }
                    .padding(32)
                } else {
                    VStack(spacing: 24) {
                        pickers
                        codeCard
                    }
                    .padding(16)
                }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.textPrimary)
    }

    // MARK: - Pickers

    private var pickers: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("BUS").sectionLabelStyle()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    ForEach(1...6, id: \.self) { number in
                        busChip(number)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("CHANGING RETURN").sectionLabelStyle()
                Picker("Changing return", selection: $lock) {
                    ForEach(MonitorSwitching.available) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("The mixer has no user accounts, so this limit lives in Mixit only. Locked: the musician can't change return. Free: one tap, for the sound lead.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("ME (THE MUSICIAN'S OWN CHANNEL)").sectionLabelStyle()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                    ForEach(Array(mixer.channels.enumerated()), id: \.offset) { index, strip in
                        channelChip(strip, number: index + 1)
                    }
                }
            }
        }
    }

    private func busChip(_ number: Int) -> some View {
        let master = mixer.master(for: .bus(number))
        return chip(isSelected: bus == number, color: master.color, title: master.displayName,
                    detail: L("Bus \(number)")) { bus = number }
    }

    private func channelChip(_ strip: Strip, number: Int) -> some View {
        chip(isSelected: me == number, color: strip.color, title: strip.displayName,
             detail: L("Ch \(number)")) { me = number }
    }

    private func chip(isSelected: Bool, color: Color, title: String, detail: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(Theme.rounded(14))
                        .lineLimit(1)
                    Text(detail)
                        .font(Theme.mono(10, .regular))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(isSelected ? Theme.controlSelected : Theme.strip, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Theme.accent.opacity(0.7) : Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Code

    private var codeCard: some View {
        VStack(spacing: 16) {
            if let pairing, let image = QRCode.image(for: pairing.code) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(16)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: 360)
                    .accessibilityLabel("Pairing QR code for \(mixer.master(for: .bus(bus)).displayName)")
                Text("On the musician's iPhone open Mixit, then More > Pair as musician and scan this code.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 6) {
                    detailLine("Mixer", pairing.host)
                    detailLine("Bus", String(pairing.bus))
                    detailLine("Me", String(pairing.me))
                    Text(pairing.code)
                        .font(Theme.mono(12, .regular))
                        .foregroundStyle(Theme.textTertiary)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("This mixer's address can't be put in a code. Check the connection.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(20)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.border, lineWidth: 1))
    }

    private func detailLine(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 14)).foregroundStyle(Theme.textTertiary)
            Spacer()
            Text(value).font(Theme.mono(15, .bold))
        }
        .accessibilityElement(children: .combine)
    }
}

/// QR code rendering with CoreImage.
enum QRCode {
    private static let context = CIContext()

    /// A crisp black-on-white QR image of the text, scaled up in whole pixels.
    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
