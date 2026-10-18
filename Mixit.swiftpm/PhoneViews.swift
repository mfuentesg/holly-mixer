import SwiftUI

/// iPhone layout (PhoneMixer.dc.html and PhoneMonitor.dc.html). Placeholder: the iPad mixer.
struct PhoneRootView: View {
    var body: some View {
        MixerView()
    }
}

/// Sheet on the iPad that shows a QR code for pairing a musician's iPhone. Placeholder.
struct MonitorPairingView: View {
    var body: some View {
        PlaceholderScreen(title: "Pair a musician's iPhone", message: "Monitor pairing is coming soon.")
    }
}
