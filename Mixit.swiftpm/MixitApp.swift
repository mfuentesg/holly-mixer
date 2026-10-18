import SwiftUI

@main
struct MixitApp: App {
    @State private var mixer = Mixer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(mixer)
                .preferredColorScheme(.dark)
        }
    }
}

struct ContentView: View {
    @Environment(Mixer.self) private var mixer
    @AppStorage("mixerHost") private var host = "192.168.1.2"
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
    }
}
