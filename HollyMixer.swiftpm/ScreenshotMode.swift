import Foundation
import UIKit

#if DEBUG
/// Debug builds only: `SIMCTL_CHILD_HM_SHOT=<name>` opens the demo mixer on a given screen, so the manual's
/// screenshots can be taken from the command line. `HM_BANK` and `HM_TAB` pick the strip bank and detail tab.
enum ScreenshotMode {
    static var name: String? { ProcessInfo.processInfo.environment["HM_SHOT"] }
    static var bank: String? { ProcessInfo.processInfo.environment["HM_BANK"] }
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
        mixer.startDemo()
        try? await Task.sleep(for: .seconds(3))
        switch name {
        case "bus2": mixer.selectedMix = .bus(2)
        case "channel": mixer.selectedStrip = .channel(3); mixer.presentedScreen = .channel(.channel(3))
        case "master": mixer.presentedScreen = .channel(.main)
        case "scenes": mixer.presentedScreen = .scenes
        case "preview":
            mixer.presentedScreen = .scenes
            try? await Task.sleep(for: .seconds(1))
            SceneStore.shared.selectedSceneID = SceneStore.shared.nextScene?.id
        case "backups": mixer.presentedScreen = .backups
        case "snapshots": mixer.presentedScreen = .snapshots
        case "pairing": mixer.presentedScreen = .monitorPairing
        case "select": mixer.selectedStrip = .channel(3)
        default: break
        }
    }
}
#endif
