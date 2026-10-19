import Foundation

/// X AIR EQ band types, in the order of the `type` parameter.
enum EQBandType: Int, CaseIterable, Identifiable {
    case lowCut, lowShelf, parametric, vintage, highShelf, highCut

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .lowCut: return L("Low cut")
        case .lowShelf: return L("Low shelf")
        case .parametric: return L("Peak (PEQ)")
        case .vintage: return L("Vintage (VEQ)")
        case .highShelf: return L("High shelf")
        case .highCut: return L("High cut")
        }
    }

    static var names: [String] { allCases.map(\.name) }

    var hasGain: Bool { self != .lowCut && self != .highCut }
    var hasQ: Bool { self == .parametric || self == .vintage }
}

/// One EQ band in real units.
struct EQBand: Equatable {
    var type: EQBandType
    var frequency: Float
    var gain: Float
    var q: Float
}

/// A second-order filter section (RBJ "Audio EQ Cookbook"), normalised by a0.
struct Biquad {
    private let b0: Double
    private let b1: Double
    private let b2: Double
    private let a1: Double
    private let a2: Double

    static let sampleRate = 48_000.0
    /// Shelves and cuts have no Q on the mixer; this is a Butterworth-like slope.
    static let fixedQ = 0.7071

    init(type: EQBandType, frequency: Double, gain: Double, q: Double) {
        let f = min(max(frequency, 1), Biquad.sampleRate * 0.45)
        let w0 = 2 * Double.pi * f / Biquad.sampleRate
        let cosW = cos(w0)
        let sinW = sin(w0)
        let amp = pow(10, gain / 40)

        var nb0 = 1.0
        var nb1 = 0.0
        var nb2 = 0.0
        var da0 = 1.0
        var da1 = 0.0
        var da2 = 0.0

        switch type {
        case .parametric, .vintage:
            let alpha = sinW / (2 * max(q, 0.05))
            nb0 = 1 + alpha * amp
            nb1 = -2 * cosW
            nb2 = 1 - alpha * amp
            da0 = 1 + alpha / amp
            da1 = -2 * cosW
            da2 = 1 - alpha / amp
        case .lowShelf:
            let alpha = sinW / (2 * Biquad.fixedQ)
            let root = 2 * sqrt(amp) * alpha
            nb0 = amp * ((amp + 1) - (amp - 1) * cosW + root)
            nb1 = 2 * amp * ((amp - 1) - (amp + 1) * cosW)
            nb2 = amp * ((amp + 1) - (amp - 1) * cosW - root)
            da0 = (amp + 1) + (amp - 1) * cosW + root
            da1 = -2 * ((amp - 1) + (amp + 1) * cosW)
            da2 = (amp + 1) + (amp - 1) * cosW - root
        case .highShelf:
            let alpha = sinW / (2 * Biquad.fixedQ)
            let root = 2 * sqrt(amp) * alpha
            nb0 = amp * ((amp + 1) + (amp - 1) * cosW + root)
            nb1 = -2 * amp * ((amp - 1) + (amp + 1) * cosW)
            nb2 = amp * ((amp + 1) + (amp - 1) * cosW - root)
            da0 = (amp + 1) - (amp - 1) * cosW + root
            da1 = 2 * ((amp - 1) - (amp + 1) * cosW)
            da2 = (amp + 1) - (amp - 1) * cosW - root
        case .lowCut:
            let alpha = sinW / (2 * Biquad.fixedQ)
            nb0 = (1 + cosW) / 2
            nb1 = -(1 + cosW)
            nb2 = (1 + cosW) / 2
            da0 = 1 + alpha
            da1 = -2 * cosW
            da2 = 1 - alpha
        case .highCut:
            let alpha = sinW / (2 * Biquad.fixedQ)
            nb0 = (1 - cosW) / 2
            nb1 = 1 - cosW
            nb2 = (1 - cosW) / 2
            da0 = 1 + alpha
            da1 = -2 * cosW
            da2 = 1 - alpha
        }

        b0 = nb0 / da0
        b1 = nb1 / da0
        b2 = nb2 / da0
        a1 = da1 / da0
        a2 = da2 / da0
    }

    /// Magnitude of the frequency response in dB.
    func decibels(at frequency: Double) -> Double {
        let w = 2 * Double.pi * frequency / Biquad.sampleRate
        let numRe = b0 + b1 * cos(w) + b2 * cos(2 * w)
        let numIm = -(b1 * sin(w) + b2 * sin(2 * w))
        let denRe = 1 + a1 * cos(w) + a2 * cos(2 * w)
        let denIm = -(a1 * sin(w) + a2 * sin(2 * w))
        let num = numRe * numRe + numIm * numIm
        let den = max(denRe * denRe + denIm * denIm, 1e-20)
        return 10 * log10(max(num, 1e-20) / den)
    }
}

/// The combined response of a strip's EQ bands and low cut.
struct EQFilterSet {
    private let filters: [Biquad]

    init(bands: [EQBand], lowCutFrequency: Float?) {
        var filters: [Biquad] = []
        if let lowCutFrequency {
            filters.append(Biquad(type: .lowCut, frequency: Double(lowCutFrequency), gain: 0, q: Biquad.fixedQ))
        }
        for band in bands {
            // A shelf or peak at 0 dB does nothing and needs no filter.
            if band.type.hasGain && abs(band.gain) < 0.01 { continue }
            filters.append(Biquad(type: band.type, frequency: Double(band.frequency),
                                  gain: Double(band.gain), q: Double(band.q)))
        }
        self.filters = filters
    }

    var isFlat: Bool { filters.isEmpty }

    func decibels(at frequency: Double) -> Double {
        filters.reduce(0) { $0 + $1.decibels(at: frequency) }
    }

    /// Response at `count` log-spaced points from 20 Hz to 20 kHz.
    func curve(count: Int) -> [Double] {
        guard count > 1 else { return [] }
        return (0..<count).map { index in
            decibels(at: EQScale.frequency(atPosition: Double(index) / Double(count - 1)))
        }
    }
}

/// Log frequency axis shared by the big graph and the thumbnails: 20 Hz to 20 kHz.
enum EQScale {
    static let low = 20.0
    static let high = 20000.0

    /// 0...1 along the axis.
    static func position(of frequency: Double) -> Double {
        let f = min(max(frequency, low), high)
        return log10(f / low) / log10(high / low)
    }

    static func frequency(atPosition position: Double) -> Double {
        low * pow(high / low, min(max(position, 0), 1))
    }
}

/// Reads a strip's EQ from the mixer's parameters (observable: call from a view body).
@MainActor
enum EQModel {
    static func isOn(_ mixer: Mixer, _ strip: Strip) -> Bool {
        mixer.param(XR18Params.eqOn(strip.base)).bool ?? false
    }

    static func lowCutIsOn(_ mixer: Mixer, _ strip: Strip) -> Bool {
        guard strip.hasPreamp else { return false }
        return mixer.param(XR18Params.preamp(strip.base, "hpon")).bool ?? false
    }

    static func lowCutFrequency(_ mixer: Mixer, _ strip: Strip) -> Float {
        mixer.realValue(XR18Params.preamp(strip.base, "hpf"), XR18Params.lowCut) ?? 20
    }

    static func band(_ mixer: Mixer, _ strip: Strip, index: Int) -> EQBand {
        let number = index + 1
        let count = strip.eqBandCount
        let defaultType: EQBandType = index == 0 ? .lowShelf : (index == count - 1 ? .highShelf : .parametric)
        let sixBand: [Float] = [60, 150, 400, 1000, 3000, 10000]
        let fourBand: [Float] = [100, 400, 2000, 8000]
        let defaultFrequency = count == 6 ? sixBand[min(index, 5)] : fourBand[min(index, 3)]
        let storedType = mixer.param(XR18Params.eq(strip.base, band: number, "type")).int
        let type = storedType.flatMap { EQBandType(rawValue: $0) } ?? defaultType
        let frequency = mixer.realValue(XR18Params.eq(strip.base, band: number, "f"), XR18Params.eqFrequency)
        let gain = mixer.realValue(XR18Params.eq(strip.base, band: number, "g"), XR18Params.eqGain)
        let q = mixer.realValue(XR18Params.eq(strip.base, band: number, "q"), XR18Params.eqQ)
        return EQBand(type: type, frequency: frequency ?? defaultFrequency, gain: gain ?? 0, q: q ?? 1)
    }

    static func bands(_ mixer: Mixer, _ strip: Strip) -> [EQBand] {
        (0..<strip.eqBandCount).map { band(mixer, strip, index: $0) }
    }

    /// The EQ as the detail page draws it: the low cut always, the bands only while EQ is on.
    static func filterSet(_ mixer: Mixer, _ strip: Strip) -> EQFilterSet {
        EQFilterSet(
            bands: isOn(mixer, strip) ? bands(mixer, strip) : [],
            lowCutFrequency: lowCutIsOn(mixer, strip) ? lowCutFrequency(mixer, strip) : nil
        )
    }

    /// The EQ as the strip thumbnail draws it: flat while EQ is off. Empty means flat.
    static func thumbnailCurve(_ mixer: Mixer, _ strip: Strip, count: Int) -> [Double] {
        guard strip.hasEQ, isOn(mixer, strip) else { return [] }
        let set = EQFilterSet(
            bands: bands(mixer, strip),
            lowCutFrequency: lowCutIsOn(mixer, strip) ? lowCutFrequency(mixer, strip) : nil
        )
        return set.isFlat ? [] : set.curve(count: count)
    }
}
