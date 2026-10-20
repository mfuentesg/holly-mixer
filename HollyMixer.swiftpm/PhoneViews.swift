import SwiftUI
import UIKit

/// iPhone layout (PhoneMixer.dc.html and PhoneMonitor.dc.html): the paired musician's "My mix",
/// otherwise the mixer, as a list of horizontal faders in portrait and the iPad mixer in landscape.
struct PhoneRootView: View {
    @Environment(Mixer.self) private var mixer
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage(MonitorPairing.storageKey) private var pairingJSON = ""
    @AppStorage("mixerHost") private var mixerHost = ""

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
