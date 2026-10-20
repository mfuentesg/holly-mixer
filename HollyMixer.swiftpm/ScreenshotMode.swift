import Foundation
import UIKit

#if DEBUG
/// Debug builds only: `SIMCTL_CHILD_HM_SHOT=<name>` opens the demo mixer on a given screen, so the manual's
/// screenshots can be taken from the command line. `HM_TAB` picks the detail tab.
enum ScreenshotMode {
    static var name: String? { ProcessInfo.processInfo.environment["HM_SHOT"] }
    static var tab: String? { ProcessInfo.processInfo.environment["HM_TAB"] }

    @MainActor
    static func run(_ mixer: Mixer) async {
        guard let name else { return }
        if ProcessInfo.processInfo.environment["HM_LANDSCAPE"] != nil {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
        }
        if name == "connect" { return }
        if name == "monitor" || name == "monitor-free" {
            let pairing = MonitorPairing(host: "demo", bus: 2, me: 3, lock: name == "monitor" ? nil : "free")
            UserDefaults.standard.set(pairing?.json, forKey: MonitorPairing.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: MonitorPairing.storageKey)
        }
        SimpleViewStore.shared.stop()
        var simple = SimpleViewConfig()
        simple.channels = [1, 5, 6]
        if name == "simple" || name == "simple-volume" {
            simple.allowsVolume = name == "simple-volume"
            SimpleViewStore.shared.start(simple)
        } else if name == "simplesettings" {
            SimpleViewStore.shared.draft = simple
        }
        mixer.startDemo()
        try? await Task.sleep(for: .seconds(3))
        if name == "simple" || name == "simple-volume" { mixer.channels[4].isOn = false }
        switch name {
        case "bus2": mixer.selectedMix = .bus(2)
        case "channel": mixer.selectedStrip = .channel(3); mixer.presentedScreen = .channel(.channel(3))
        case "master": mixer.presentedScreen = .channel(.main)
        case "backups": mixer.presentedScreen = .backups
        case "settings": mixer.presentedScreen = .settings
        case "mutegroups": mixer.presentedScreen = .muteGroups
        case "snapshots": mixer.presentedScreen = .snapshots
        case "silenced": mixer.toggleMuteGroup(1)
        case "help": mixer.presentedScreen = .help
        case "simplesettings": mixer.presentedScreen = .simpleView
        case "select": mixer.selectedStrip = .channel(3)
        default: break
        }
    }
}
#endif
