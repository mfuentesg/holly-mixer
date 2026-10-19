import Foundation
import Observation
import SwiftUI

/// One of the four DCA groups of the XR18: a single fader (and mute) for a set of channels.
/// Addresses: `/dca/N/on`, `/dca/N/fader`, `/dca/N/config/name|color`. Which channels belong to it is stored on
/// each channel as a bit mask in `/ch/NN/grp/dca` (bit 0 = DCA 1).
@MainActor
@Observable
final class DCAGroup: Identifiable {
    let number: Int
    var name = ""
    var colorIndex = 0
    var fader: Float = 0.75
    var isOn = true

    nonisolated var id: Int { number }

    init(number: Int) {
        self.number = number
    }

    var base: String { "/dca/\(number)" }
    var faderAddress: String { "\(base)/fader" }
    var onAddress: String { "\(base)/on" }

    var displayName: String { name.isEmpty ? L("DCA \(number)") : name }
    var color: Color { Theme.channelColors[colorIndex % 8] }

    /// Applies a value from the mixer.
    func apply(_ field: String, _ argument: OSCArgument?) {
        switch (field, argument) {
        case ("fader", .float(let value)?): fader = value
        case ("on", .int(let value)?): isOn = value != 0
        case ("config/name", .string(let value)?): name = value
        case ("config/color", .int(let value)?): colorIndex = Int(value)
        default: break
        }
    }

    /// Addresses to read when connecting.
    var syncAddresses: [String] {
        ["on", "fader", "config/name", "config/color"].map { "\(base)/\($0)" }
    }
}
