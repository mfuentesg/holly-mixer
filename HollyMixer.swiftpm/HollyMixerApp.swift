import SwiftUI
import UIKit

@main
struct HollyMixerApp: App {
    @State private var mixer = Mixer()
    @State private var localization = Localization.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundTask = UIBackgroundTaskIdentifier.invalid

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
                .onChange(of: scenePhase) { _, phase in handle(phase) }
                // A locked screen freezes the connection, so keep the screen on while controlling a mixer.
                .onChange(of: mixer.hasSession, initial: true) { _, active in
                    UIApplication.shared.isIdleTimerDisabled = active
                }
        }
    }

    private func handle(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // iOS gives a few extra seconds: enough to keep the link alive through a quick switch to another app.
            guard backgroundTask == .invalid else { return }
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "mixer-link") {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        case .active:
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
            mixer.resumeAfterBackground()
        default:
            break
        }
    }
}

struct ContentView: View {
    @Environment(Mixer.self) private var mixer
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("mixerHost") private var host = ""
    @AppStorage("recentMixers") private var recentJSON = "[]"
    @AppStorage(MonitorPairing.storageKey) private var pairingJSON = ""
    @State private var didAutoConnect = false
    private let simpleView = SimpleViewStore.shared

    var body: some View {
        Group {
            if mixer.hasSession {
                if simpleView.active != nil {
                    SimpleView()
                } else if sizeClass == .compact {
                    PhoneRootView()
                } else {
                    MixerView()
                }
            } else {
                ConnectView(host: $host, onPair: join)
            }
        }
        .task {
            // Reconnect to the last mixer on launch.
            BackupStore.shared.attach(mixer)
            guard !didAutoConnect else { return }
            didAutoConnect = true
            #if DEBUG
            if ScreenshotMode.name != nil {
                await ScreenshotMode.run(mixer)
                return
            }
            #endif
            // Nothing is assumed the first time: with no saved address the connect screen scans the network.
            guard !host.isEmpty else { return }
            mixer.connect(host: host)
            await findMixerIfAddressChanged(saved: host)
        }
        .onChange(of: mixer.hasSession) { _, hasSession in
            guard hasSession, !mixer.isDemo else { return }
            rememberMixer()
        }
    }

    /// The church's router may hand the mixer a new address. If the saved one doesn't answer, look for the mixer on
    /// the network and follow it when it is clearly the same one (same name as a recent mixer, or the only one found).
    private func findMixerIfAddressChanged(saved: String) async {
        try? await Task.sleep(for: .seconds(4))
        guard !mixer.hasSession, !mixer.isDemo, mixer.host == saved else { return }
        let found = await MixerDiscovery.scan()
        guard !mixer.hasSession, !mixer.isDemo, mixer.host == saved else { return }
        let recentNames = Set(RecentMixer.load(from: recentJSON).map(\.name))
        let match = found.first { recentNames.contains($0.name) } ?? (found.count == 1 ? found.first : nil)
        guard let match, match.ip != saved else { return }
        host = match.ip
        mixer.connect(host: match.ip)
    }

    /// A musician paired from the Connect screen: remember it and connect to its mixer.
    private func join(_ pairing: MonitorPairing) {
        pairingJSON = pairing.json
        if pairing.isDemo {
            mixer.startDemo()
        } else {
            host = pairing.host
            mixer.connect(host: pairing.host)
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
