import Foundation
import Observation

/// Names for the four mute groups. The XR18 cannot store them, so they live in the app on this device.
@MainActor
@Observable
final class MuteGroupNames {
    static let shared = MuteGroupNames()
    static let limit = 12
    private static let key = "muteGroupNames"

    private(set) var names: [String]

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        names = (0..<4).map { $0 < stored.count ? stored[$0] : "" }
    }

    /// The name, or "" when the group has none.
    func name(_ group: Int) -> String { names[group - 1] }

    func set(_ group: Int, to name: String) {
        names[group - 1] = String(name.prefix(Self.limit))
        UserDefaults.standard.set(names, forKey: Self.key)
    }
}
