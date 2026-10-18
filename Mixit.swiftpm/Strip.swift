import Foundation
import Observation
import SwiftUI

/// Which mix the faders control: the main LR fader, or the sends to a bus or FX send.
enum MixTarget: Hashable {
    case main
    case bus(Int)
    case fxSend(Int)

    /// Index into `Strip.sends`: buses 1-6 are `mix/01`-`mix/06`, FX sends 1-4 are `mix/07`-`mix/10`.
    var sendIndex: Int? {
        switch self {
        case .main: return nil
        case .bus(let number): return number - 1
        case .fxSend(let number): return 5 + number
        }
    }

    var control: LevelControl {
        sendIndex.map { .send($0) } ?? .fader
    }
}

/// A level a fader can control on a strip.
enum LevelControl: Hashable {
    case fader
    case send(Int)

    var path: String {
        switch self {
        case .fader: return "mix/fader"
        case .send(let index): return String(format: "mix/%02d/level", index + 1)
        }
    }
}

/// One fader strip: an input, a bus or FX send master, or the main LR bus.
@MainActor
@Observable
final class Strip: Identifiable {
    enum Kind: Hashable {
        case channel(Int)
        case auxIn
        case fxReturn(Int)
        case bus(Int)
        case fxSend(Int)
        case main
    }

    let id: Kind
    /// OSC address prefix, e.g. "/ch/01", "/rtn/aux", "/bus/3" or "/lr".
    let base: String

    var name = ""
    var colorIndex = 0
    /// Fader position 0...1 as the mixer stores it (0.75 = 0 dB).
    var fader: Float = 0
    /// `mix/on`: true means the strip is NOT muted.
    var isOn = true
    /// Latest meter level in dBFS.
    var meter: Float = -90
    /// Send levels (same 0...1 taper as faders), see `MixTarget.sendIndex`.
    var sends: [Float]

    var kind: Kind { id }

    init(kind: Kind) {
        self.id = kind
        let sendCount: Int
        switch kind {
        case .channel(let number):
            base = String(format: "/ch/%02d", number)
            sendCount = 10
        case .auxIn:
            base = "/rtn/aux"
            sendCount = 10
        case .fxReturn(let number):
            base = "/rtn/\(number)"
            sendCount = 6
        case .bus(let number):
            base = "/bus/\(number)"
            sendCount = 0
        case .fxSend(let number):
            base = "/fxsend/\(number)"
            sendCount = 0
        case .main:
            base = "/lr"
            sendCount = 0
        }
        sends = Array(repeating: 0, count: sendCount)
    }

    var displayName: String {
        if !name.isEmpty { return name }
        switch kind {
        case .channel(let number): return "Ch \(number)"
        case .auxIn: return "Aux In"
        case .fxReturn(let number): return "FX \(number) Rtn"
        case .bus(let number): return "Bus \(number)"
        case .fxSend(let number): return "FX \(number)"
        case .main: return "Main LR"
        }
    }

    /// Short label shown above the name: "1"..."16", "AUX", "FX1", "B1", "LR".
    var shortLabel: String {
        switch kind {
        case .channel(let number): return "\(number)"
        case .auxIn: return "AUX"
        case .fxReturn(let number): return "FX\(number)"
        case .bus(let number): return "BUS \(number)"
        case .fxSend(let number): return "FX \(number)"
        case .main: return "LR"
        }
    }

    /// X AIR colour indices 0-7 (8-15 are the same colours, inverted on the mixer's scribble strip).
    static let palette: [Color] = [
        Color(white: 0.45),
        Color(red: 0.96, green: 0.34, blue: 0.34),
        Color(red: 0.3, green: 0.82, blue: 0.46),
        Color(red: 0.98, green: 0.8, blue: 0.26),
        Color(red: 0.32, green: 0.56, blue: 0.98),
        Color(red: 0.86, green: 0.42, blue: 0.88),
        Color(red: 0.3, green: 0.78, blue: 0.92),
        Color(white: 0.92),
    ]

    var color: Color { Strip.palette[colorIndex % 8] }

    var labelTextColor: Color {
        [2, 3, 6, 7].contains(colorIndex % 8) ? .black : .white
    }

    func hasControl(_ control: LevelControl) -> Bool {
        switch control {
        case .fader: return true
        case .send(let index): return index < sends.count
        }
    }

    func level(_ control: LevelControl) -> Float {
        switch control {
        case .fader: return fader
        case .send(let index): return index < sends.count ? sends[index] : 0
        }
    }

    func setLevel(_ value: Float, for control: LevelControl) {
        switch control {
        case .fader: fader = value
        case .send(let index): if index < sends.count { sends[index] = value }
        }
    }

    func address(_ control: LevelControl) -> String {
        "\(base)/\(control.path)"
    }

    var syncAddresses: [String] {
        let paths = ["config/name", "config/color", "mix/fader", "mix/on"]
            + sends.indices.map { LevelControl.send($0).path }
        return paths.map { "\(base)/\($0)" }
    }

    func apply(_ path: String, _ arguments: [OSCArgument]) {
        switch (path, arguments.first) {
        case ("mix/fader", .float(let value)?):
            fader = value
        case ("mix/on", .int(let value)?):
            isOn = value != 0
        case ("config/name", .string(let value)?):
            name = value
        case ("config/color", .int(let value)?):
            colorIndex = Int(value)
        case (_, .float(let value)?) where path.hasPrefix("mix/") && path.hasSuffix("/level"):
            // "mix/03/level" -> send index 2
            if let number = Int(path.dropFirst(4).prefix(2)), number >= 1, number <= sends.count {
                sends[number - 1] = value
            }
        default:
            break
        }
    }
}
