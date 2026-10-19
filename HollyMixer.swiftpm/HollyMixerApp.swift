import SwiftUI

@main
struct HollyMixerApp: App {
    @State private var mixer = Mixer()
    @State private var localization = Localization.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(mixer)
                .environment(localization)
                .environment(\.locale, localization.locale)
                // A language change rebuilds the screen so every text is looked up again.
                .id(localization.language)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct ContentView: View {
    @Environment(Mixer.self) private var mixer
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("mixerHost") private var host = "192.168.1.2"
    @AppStorage("recentMixers") private var recentJSON = "[]"
    @State private var didAutoConnect = false

    var body: some View {
        Group {
            if mixer.hasSession {
                if sizeClass == .compact {
                    PhoneRootView()
                } else {
                    MixerView()
                }
            } else {
                ConnectView(host: $host)
            }
        }
        .task {
            // Reconnect to the last mixer on launch.
            BackupStore.shared.attach(mixer)
            guard !didAutoConnect else { return }
            didAutoConnect = true
            mixer.connect(host: host)
        }
        .onChange(of: mixer.hasSession) { _, hasSession in
            guard hasSession, !mixer.isDemo else { return }
            rememberMixer()
        }
    }

    /// Puts the connected mixer at the top of the recent list.
    private func rememberMixer() {
        let entry = RecentMixer(ip: mixer.host, name: mixer.mixerName.isEmpty ? mixer.host : mixer.mixerName,
                                lastUsed: Date())
        let others = RecentMixer.load(from: recentJSON).filter { $0.ip != entry.ip }
        recentJSON = RecentMixer.save(Array(([entry] + others).prefix(6)))
        host = mixer.host
    }
}
