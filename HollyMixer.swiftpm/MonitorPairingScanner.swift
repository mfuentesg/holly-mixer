import SwiftUI
import UIKit
import VisionKit

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

    static let storageKey = "monitorPairing"

    init?(host: String, bus: Int, me: Int, lock: String? = nil) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidHost(trimmed), (1...6).contains(bus), (1...16).contains(me) else { return nil }
        self.host = trimmed
        self.bus = bus
        self.me = me
        self.lock = ["pin", "free"].contains(lock ?? "") ? lock : nil
    }

    /// How this iPhone may change its return. A "pin" code scanned while Service Mode is off counts as locked.
    var switching: MonitorSwitching {
        let mode = MonitorSwitching(rawValue: lock ?? "") ?? .locked
        return MonitorSwitching.available.contains(mode) ? mode : .locked
    }

    /// Parses `hollymixer://monitor?host=<host>&bus=<n>&me=<n>`; nil for anything else.
    init?(code: String) {
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: text),
              components.scheme?.lowercased() == "hollymixer",
              components.host?.lowercased() == "monitor" else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let host = value("host"), let bus = value("bus").flatMap({ Int($0) }),
              let me = value("me").flatMap({ Int($0) }) else { return nil }
        self.init(host: host, bus: bus, me: me, lock: value("lock"))
    }

    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_:"))
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// The text encoded in the QR code.
    var code: String {
        var components = URLComponents()
        components.scheme = "hollymixer"
        components.host = "monitor"
        components.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "bus", value: String(bus)),
            URLQueryItem(name: "me", value: String(me)),
        ] + (lock.map { [URLQueryItem(name: "lock", value: $0)] } ?? [])
        return components.string ?? "hollymixer://monitor?host=\(host)&bus=\(bus)&me=\(me)"
    }

    var isDemo: Bool { host == "demo" }

    var json: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// Reads a pairing stored with `json`; nil for empty or corrupt text.
    static func decode(_ json: String) -> MonitorPairing? {
        guard let data = json.data(using: .utf8), !data.isEmpty,
              let stored = try? JSONDecoder().decode(MonitorPairing.self, from: data) else { return nil }
        return MonitorPairing(host: stored.host, bus: stored.bus, me: stored.me, lock: stored.lock)
    }
}

/// Whether and how an iPhone in musician mode may change which return (bus) it controls.
enum MonitorSwitching: String, CaseIterable, Identifiable {
    /// Fixed to one bus; leaving needs a long press (and re-pairing to change).
    case locked
    /// Changing needs the Service Mode PIN.
    case pin
    /// Changing is one tap, for the sound lead.
    case free

    var id: String { rawValue }

    /// The options to offer: the PIN one needs Service Mode's PIN, which is off in this version.
    static var available: [MonitorSwitching] {
        allCases.filter { $0 != .pin || FeatureFlags.serviceMode }
    }

    var title: String {
        switch self {
        case .locked: return L("Locked")
        case .pin: return L("With PIN")
        case .free: return L("Free")
        }
    }
}

/// Sheet on the iPhone for joining as a musician: scan the iPad's QR code, or type the details.
struct MonitorPairingScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onPair: (MonitorPairing) -> Void

    @State private var hostText = ""
    @State private var bus = 1
    @State private var me = 1
    @State private var lock = MonitorSwitching.locked
    @State private var message: String?
    @State private var showsManualEntry = !QRScannerView.isAvailable

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pair as musician")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                Button("Cancel") { dismiss() }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accentText)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            ScrollView {
                VStack(spacing: 16) {
                    if QRScannerView.isAvailable {
                        scanner
                    } else {
                        Text("The camera can't scan codes on this device. Enter the details shown on the sound desk's iPad.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if let message {
                        Text(message)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.meterRed)
                    }
                    manualEntry
                }
                .padding(16)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.textPrimary)
    }

    private var scanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Point the camera at the code on the sound desk's iPad.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
            QRScannerView { code in
                if let pairing = MonitorPairing(code: code) {
                    onPair(pairing)
                } else {
                    message = "That isn't a Holly Mixer pairing code."
                }
            }
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.borderStrong, lineWidth: 1))
            .accessibilityLabel("QR code scanner")
        }
    }

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation { showsManualEntry.toggle() }
            } label: {
                HStack {
                    Text("Enter manually")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Image(systemName: showsManualEntry ? "chevron.up" : "chevron.down")
                }
                .foregroundStyle(Theme.textControl)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)

            if showsManualEntry {
                TextField("Mixer address (e.g. 192.168.1.2)", text: $hostText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(Theme.mono(16, .regular))
                    .padding(.horizontal, 12)
                    .frame(height: 48)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                Stepper("Bus \(bus)", value: $bus, in: 1...6)
                    .frame(minHeight: 44)
                Stepper("My channel \(me)", value: $me, in: 1...16)
                    .frame(minHeight: 44)
                Picker("Changing return", selection: $lock) {
                    ForEach(MonitorSwitching.available) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Button {
                    join()
                } label: {
                    Text("Join")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func join() {
        if let pairing = MonitorPairing(host: hostText, bus: bus, me: me, lock: lock == .locked ? nil : lock.rawValue) {
            onPair(pairing)
        } else {
            message = "Enter the mixer's address, like 192.168.1.2."
        }
    }
}

/// Camera view that reads QR codes with VisionKit.
struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    /// False on the simulator, without a camera or when camera access is denied.
    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
        context.coordinator.start(controller)
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void
        private var didStart = false
        private var lastCode: String?

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        /// Starts scanning once the view is on screen, retrying briefly if it isn't yet.
        func start(_ controller: DataScannerViewController) {
            guard !didStart else { return }
            didStart = true
            Task { @MainActor in
                for _ in 0..<4 {
                    try? await Task.sleep(for: .milliseconds(150))
                    if controller.isScanning { return }
                    if (try? controller.startScanning()) != nil { return }
                }
                didStart = false
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems { handle(item) }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            handle(item)
        }

        private func handle(_ item: RecognizedItem) {
            guard case .barcode(let barcode) = item, let code = barcode.payloadStringValue,
                  code != lastCode else { return }
            lastCode = code
            onCode(code)
        }
    }
}
