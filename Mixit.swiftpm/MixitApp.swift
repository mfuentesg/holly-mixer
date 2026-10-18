import SwiftUI

@main
struct MixitApp: App {
    @State private var mixer = Mixer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(mixer)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct ContentView: View {
    @Environment(Mixer.self) private var mixer
    @AppStorage("mixerHost") private var host = "192.168.1.2"
    @AppStorage("recentMixers") private var recentJSON = "[]"
    @State private var didAutoConnect = false

    var body: some View {
        Group {
            if mixer.hasSession {
                MixerView()
            } else {
                ConnectView(host: $host)
            }
        }
        .task {
            // Reconnect to the last mixer on launch.
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
