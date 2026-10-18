import Foundation

/// Range of a continuous X AIR parameter. OSC carries 0...1; this converts to and from real units.
/// Linear: `lower + (upper - lower) * x`. Log: `lower * (upper / lower) ^ x`.
struct ParamRange {
    let lower: Float
    let upper: Float
    var isLog = false

    /// Real value for an OSC position (clamped to 0...1).
    func value(_ normalized: Float) -> Float {
        let x = Swift.min(Swift.max(normalized, 0), 1)
        if isLog { return lower * powf(upper / lower, x) }
        return lower + (upper - lower) * x
    }

    /// OSC position (0...1) for a real value (clamped to the range).
    func normalized(_ value: Float) -> Float {
        let low = Swift.min(lower, upper)
        let high = Swift.max(lower, upper)
        let v = Swift.min(Swift.max(value, low), high)
        if isLog { return logf(v / lower) / logf(upper / lower) }
        return (v - lower) / (upper - lower)
    }
}

/// Every XR18 OSC address and value mapping used by the channel detail page, in one place.
/// All of these come from the X AIR OSC documentation and community notes: verify on hardware.
enum XR18Params {
    // MARK: Ranges (verify on hardware)

    static let preampGain = ParamRange(lower: -12, upper: 60)
    static let lowCut = ParamRange(lower: 20, upper: 400, isLog: true)

    static let gateThreshold = ParamRange(lower: -80, upper: 0)
    static let gateRange = ParamRange(lower: 3, upper: 60)
    static let gateAttack = ParamRange(lower: 0, upper: 120)
    static let gateHold = ParamRange(lower: 0.02, upper: 2000, isLog: true)
    static let gateRelease = ParamRange(lower: 5, upper: 4000, isLog: true)

    static let eqFrequency = ParamRange(lower: 20, upper: 20000, isLog: true)
    static let eqGain = ParamRange(lower: -15, upper: 15)
    /// 0 is Q 10 (narrow) and 1 is Q 0.3 (wide).
    static let eqQ = ParamRange(lower: 10, upper: 0.3, isLog: true)

    static let dynThreshold = ParamRange(lower: -60, upper: 0)
    static let dynKnee = ParamRange(lower: 0, upper: 5)
    static let dynMakeup = ParamRange(lower: 0, upper: 24)
    static let dynAttack = ParamRange(lower: 0, upper: 120)
    static let dynHold = ParamRange(lower: 0.02, upper: 2000, isLog: true)
    static let dynRelease = ParamRange(lower: 5, upper: 4000, isLog: true)
    static let dynMix = ParamRange(lower: 0, upper: 100)

    // MARK: Enumerations

    static let gateModes = ["EXP2", "EXP3", "EXP4", "GATE", "DUCK"]
    static let dynModes = ["COMP", "EXP"]
    static let detectors = ["PEAK", "RMS"]
    static let envelopes = ["LIN", "LOG"]
    /// `dyn/ratio` is an index into this list.
    static let dynRatios: [Float] = [1.1, 1.3, 1.5, 2, 2.5, 3, 4, 5, 7, 10, 20, 100]
    static let dynRatioLabels: [String] = dynRatios.map { ratio in
        ratio == ratio.rounded() ? "\(Int(ratio)):1" : String(format: "%.1f:1", ratio)
    }

    // MARK: Addresses

    static func headamp(_ number: Int, _ field: String) -> String {
        String(format: "/headamp/%02d/", number) + field
    }

    static func preamp(_ base: String, _ field: String) -> String { "\(base)/preamp/\(field)" }
    static func gate(_ base: String, _ field: String) -> String { "\(base)/gate/\(field)" }
    static func dyn(_ base: String, _ field: String) -> String { "\(base)/dyn/\(field)" }
    static func eqOn(_ base: String) -> String { "\(base)/eq/on" }
    /// `band` is 1-based, `field` is "type", "f", "g" or "q".
    static func eq(_ base: String, band: Int, _ field: String) -> String { "\(base)/eq/\(band)/\(field)" }

    static let gateFields = ["on", "mode", "thr", "range", "attack", "hold", "release"]
    static let dynFields = ["on", "mode", "det", "env", "thr", "ratio", "knee", "mgain",
                            "attack", "hold", "release", "mix", "auto"]

    /// Addresses a strip's EQ curve needs (used by the strip thumbnail).
    @MainActor static func thumbnailAddresses(for strip: Strip) -> [String] {
        guard strip.hasEQ else { return [] }
        return eqAddresses(for: strip) + lowCutAddresses(for: strip)
    }

    @MainActor static func eqAddresses(for strip: Strip) -> [String] {
        guard strip.hasEQ else { return [] }
        var addresses = [eqOn(strip.base)]
        for band in 1...strip.eqBandCount {
            addresses += ["type", "f", "g", "q"].map { eq(strip.base, band: band, $0) }
        }
        return addresses
    }

    @MainActor static func lowCutAddresses(for strip: Strip) -> [String] {
        guard strip.hasPreamp else { return [] }
        return [preamp(strip.base, "hpon"), preamp(strip.base, "hpf")]
    }

    /// Everything the detail page shows for a strip.
    @MainActor static func detailAddresses(for strip: Strip) -> [String] {
        var addresses = eqAddresses(for: strip) + lowCutAddresses(for: strip)
        if let number = strip.channelNumber {
            addresses += ["gain", "phantom"].map { headamp(number, $0) }
            addresses.append(preamp(strip.base, "invert"))
        }
        if strip.hasGate {
            addresses += gateFields.map { gate(strip.base, $0) }
        }
        if strip.hasDynamics {
            addresses += dynFields.map { dyn(strip.base, $0) }
        }
        addresses += ["config/name", "config/color"].map { "\(strip.base)/\($0)" }
        return addresses
    }
}

/// Which sections of the detail page and which parameters a strip has.
extension Strip {
    /// 1...16 for input channels.
    var channelNumber: Int? {
        if case .channel(let number) = kind { return number }
        return nil
    }

    var hasPreamp: Bool { isChannel }
    var hasGate: Bool { isChannel }

    var hasEQ: Bool {
        if case .fxSend = kind { return false }
        return true
    }

    /// Channels, aux and FX returns have 4 bands; buses and main have 6.
    var eqBandCount: Int {
        switch kind {
        case .channel, .auxIn, .fxReturn: return 4
        case .bus, .main: return 6
        case .fxSend: return 0
        }
    }

    var hasDynamics: Bool {
        switch kind {
        case .channel, .bus, .main: return true
        default: return false
        }
    }

    var hasSendLevels: Bool { !sends.isEmpty }
}

/// Number formatting for readouts: true minus sign, one place to change decimals.
enum ParamFormat {
    /// "+3.0", "−2.5", "0.0".
    static func signed(_ value: Float, decimals: Int = 1) -> String {
        let text = String(format: "%.\(decimals)f", abs(value))
        if Float(text) == 0 { return text }
        return (value < 0 ? "−" : "+") + text
    }

    /// "−30.0" or "12.5" (minus sign only).
    static func plain(_ value: Float, decimals: Int = 1) -> String {
        let text = String(format: "%.\(decimals)f", abs(value))
        if value < 0, Float(text) != 0 { return "−" + text }
        return text
    }

    /// "100", "1.20k", "12.5k".
    static func frequency(_ hertz: Float) -> String {
        if hertz >= 10000 { return String(format: "%.1fk", hertz / 1000) }
        if hertz >= 1000 { return String(format: "%.2fk", hertz / 1000) }
        if hertz >= 100 { return String(format: "%.0f", hertz) }
        return String(format: "%.1f", hertz)
    }

    /// "0.5 ms", "120 ms", "1.50 s".
    static func time(_ milliseconds: Float) -> String {
        if milliseconds >= 1000 { return String(format: "%.2f s", milliseconds / 1000) }
        if milliseconds >= 100 { return String(format: "%.0f ms", milliseconds) }
        if milliseconds >= 10 { return String(format: "%.1f ms", milliseconds) }
        return String(format: "%.2f ms", milliseconds)
    }
}

extension Mixer {
    /// The real-unit value of a continuous parameter, or nil until the mixer has answered.
    func realValue(_ address: String, _ range: ParamRange) -> Float? {
        param(address).float.map { range.value($0) }
    }
}
