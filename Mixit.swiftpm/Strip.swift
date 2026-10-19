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
    /// Pan 0...1 as the mixer stores it (0.5 = centre).
    var pan: Float = 0.5
    var gateOn = false
    var compressorOn = false
    var isSoloed = false
    /// Latest meter level in dBFS (left, or mono).
    var meter: Float = -90
    /// Right channel of a stereo meter, if the strip has one.
    var meterRight: Float?
    /// Peak-hold level in dBFS, decaying slowly.
    var peak: Float = -90
    /// Send levels (same 0...1 taper as faders), see `MixTarget.sendIndex`.
    var sends: [Float]
    /// Briefly true after another client (X AIR, another iPad, the mixer) changed this strip.
    var changedElsewhere = false

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
        case .channel(let number): return L("Ch \(number)")
        case .auxIn: return L("Aux In")
        case .fxReturn(let number): return L("FX \(number) Rtn")
        case .bus(let number): return L("Bus \(number)")
        case .fxSend(let number): return L("FX \(number)")
        case .main: return L("Main LR")
        }
    }

    /// Short label above the name and in mix chips: "1"..."16", "AUX", "FX1", "B1", "MAIN".
    var shortLabel: String {
        switch kind {
        case .channel(let number): return "\(number)"
        case .auxIn: return "AUX"
        case .fxReturn(let number): return "FX\(number)"
        case .bus(let number): return "B\(number)"
        case .fxSend(let number): return "FX\(number)"
        case .main: return "MAIN"
        }
    }

    var isChannel: Bool {
        if case .channel = kind { return true }
        return false
    }

    /// Channel solo switch, `/-stat/solosw/01`-`16` (channels only for now).
    var soloAddress: String? {
        if case .channel(let number) = kind { return String(format: "/-stat/solosw/%02d", number) }
        return nil
    }

    /// False for unnamed strips left at the default grey; they are drawn dimmer.
    var isNamed: Bool { !name.isEmpty || colorIndex % 8 != 0 }

    var color: Color { Theme.channelColors[colorIndex % 8] }
    var onColor: Color { Theme.onChannelColors[colorIndex % 8] }

    var hasPan: Bool {
        switch kind {
        case .channel, .auxIn, .fxReturn: return true
        default: return false
        }
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
        var paths = ["config/name", "config/color", "mix/fader", "mix/on"]
            + sends.indices.map { LevelControl.send($0).path }
        if hasPan { paths.append("mix/pan") }
        if isChannel { paths += ["gate/on", "dyn/on"] }
        var addresses = paths.map { "\(base)/\($0)" }
        if let soloAddress { addresses.append(soloAddress) }
        return addresses
    }

    /// Applies a value from the mixer. Returns true if a fader or mute changed.
    @discardableResult
    func apply(_ path: String, _ arguments: [OSCArgument]) -> Bool {
        switch (path, arguments.first) {
        case ("mix/fader", .float(let value)?):
            defer { fader = value }
            return fader != value
        case ("mix/on", .int(let value)?):
            defer { isOn = value != 0 }
            return isOn != (value != 0)
        case ("mix/pan", .float(let value)?):
            pan = value
        case ("gate/on", .int(let value)?):
            gateOn = value != 0
        case ("dyn/on", .int(let value)?):
            compressorOn = value != 0
        case ("config/name", .string(let value)?):
            name = value
        case ("config/color", .int(let value)?):
            colorIndex = Int(value)
        case (_, .float(let value)?) where path.hasPrefix("mix/") && path.hasSuffix("/level"):
            // "mix/03/level" -> send index 2
            if let number = Int(path.dropFirst(4).prefix(2)), number >= 1, number <= sends.count {
                defer { sends[number - 1] = value }
                return sends[number - 1] != value
            }
        default:
            break
        }
        return false
    }

    /// Updates the meter and its decaying peak hold.
    func setMeter(_ level: Float, right: Float? = nil) {
        meter = level
        meterRight = right
        let loudest = max(level, right ?? level)
        peak = max(loudest, peak - 0.6)
    }
}
