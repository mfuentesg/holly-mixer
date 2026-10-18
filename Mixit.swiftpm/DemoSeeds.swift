import Foundation

/// Extra starting values for the demo mixer, added on top of DemoTransport's own state.
enum DemoSeeds {
    /// One EQ band as the design's sample EQs describe it.
    private struct Band {
        let type: EQBandType
        let frequency: Float
        let gain: Float
        var q: Float = 1
    }

    /// A sample EQ: optional low cut plus the bands in order.
    private struct EQPreset {
        var lowCut: Float?
        var bands: [Band]
    }

    /// Sample dynamics settings (compressor), in real units.
    private struct DynamicsPreset {
        let threshold: Float
        let ratioIndex: Int32
        let knee: Float
        let makeup: Float
        let attack: Float
        let release: Float
        var rms = false
    }

    private static let vocal = EQPreset(lowCut: 100, bands: [
        Band(type: .lowShelf, frequency: 150, gain: -2),
        Band(type: .parametric, frequency: 350, gain: -3, q: 1.2),
        Band(type: .parametric, frequency: 3000, gain: 3, q: 1),
        Band(type: .highShelf, frequency: 10000, gain: 2),
    ])
    private static let guitar = EQPreset(lowCut: 80, bands: [
        Band(type: .parametric, frequency: 200, gain: -3, q: 1),
        Band(type: .parametric, frequency: 5000, gain: 2, q: 0.8),
    ])
    private static let bass = EQPreset(lowCut: 35, bands: [
        Band(type: .parametric, frequency: 80, gain: 3, q: 1),
        Band(type: .parametric, frequency: 800, gain: -3, q: 1.5),
    ])
    private static let drums = EQPreset(lowCut: 40, bands: [
        Band(type: .parametric, frequency: 400, gain: -4, q: 1),
        Band(type: .highShelf, frequency: 8000, gain: 3),
    ])
    private static let flat = EQPreset(lowCut: nil, bands: [])
    private static let main = EQPreset(lowCut: nil, bands: [
        Band(type: .lowShelf, frequency: 60, gain: 1.5),
        Band(type: .parametric, frequency: 250, gain: -1.5, q: 1),
        Band(type: .parametric, frequency: 2500, gain: -1, q: 1.4),
        Band(type: .highShelf, frequency: 12000, gain: 1),
    ])
    private static let monitor = EQPreset(lowCut: nil, bands: [
        Band(type: .parametric, frequency: 500, gain: -2, q: 1),
        Band(type: .highShelf, frequency: 9000, gain: -2),
    ])

    /// Per channel: EQ sample, preamp gain in dB, and (for gated/compressed channels) dynamics.
    private static let channelPlan: [(eq: EQPreset, gain: Float, dynamics: DynamicsPreset?)] = [
        (vocal, 24, DynamicsPreset(threshold: -20, ratioIndex: 5, knee: 2, makeup: 4, attack: 10, release: 120)),
        (vocal, 26, DynamicsPreset(threshold: -22, ratioIndex: 5, knee: 2, makeup: 4, attack: 10, release: 120)),
        (guitar, 12, nil),
        (bass, 10, DynamicsPreset(threshold: -16, ratioIndex: 6, knee: 1, makeup: 3, attack: 25, release: 200)),
        (vocal, 25, DynamicsPreset(threshold: -21, ratioIndex: 5, knee: 2, makeup: 4, attack: 10, release: 120)),
        (vocal, 28, DynamicsPreset(threshold: -24, ratioIndex: 5, knee: 2, makeup: 5, attack: 10, release: 120)),
        (vocal, 24, nil),
        (guitar, 14, nil),
        (guitar, 12, nil),
        (drums, 18, DynamicsPreset(threshold: -14, ratioIndex: 4, knee: 0, makeup: 2, attack: 5, release: 90)),
        (guitar, 13, nil),
        (flat, 0, nil), (flat, 0, nil), (flat, 0, nil), (flat, 0, nil), (flat, 0, nil),
    ]

    /// Preamp, gate, EQ and dynamics values for channels, buses and main.
    static func channelDetail() -> [String: OSCArgument] {
        var values: [String: OSCArgument] = [:]

        for (index, plan) in channelPlan.enumerated() {
            let number = index + 1
            let base = String(format: "/ch/%02d", number)
            let isUsed = number <= 11
            values[XR18Params.headamp(number, "gain")] = .float(XR18Params.preampGain.normalized(plan.gain))
            values[XR18Params.headamp(number, "phantom")] = .int(0)
            values[XR18Params.preamp(base, "invert")] = .int(0)
            seedLowCut(&values, base: base, frequency: plan.eq.lowCut)
            seedEQ(&values, base: base, bandCount: 4, preset: plan.eq, isOn: isUsed)
            seedGate(&values, base: base, isVocal: plan.eq.lowCut == 100)
            seedDynamics(&values, base: base, preset: plan.dynamics, isOn: plan.dynamics != nil)
        }

        let returnPreset = EQPreset(lowCut: nil, bands: [
            Band(type: .parametric, frequency: 300, gain: -2, q: 1),
            Band(type: .highShelf, frequency: 9000, gain: -1.5),
        ])
        seedEQ(&values, base: "/rtn/aux", bandCount: 4, preset: flat, isOn: true)
        for number in 1...4 {
            seedEQ(&values, base: "/rtn/\(number)", bandCount: 4, preset: returnPreset, isOn: true)
        }

        for number in 1...6 {
            let base = "/bus/\(number)"
            let preset = number <= 3 ? monitor : flat
            seedEQ(&values, base: base, bandCount: 6, preset: preset, isOn: number <= 3)
            let dynamics = DynamicsPreset(threshold: -12, ratioIndex: 4, knee: 1, makeup: 0, attack: 20, release: 250)
            seedDynamics(&values, base: base, preset: dynamics, isOn: number <= 3)
        }

        seedEQ(&values, base: "/lr", bandCount: 6, preset: main, isOn: true)
        let mainDynamics = DynamicsPreset(threshold: -8, ratioIndex: 3, knee: 2, makeup: 0, attack: 30,
                                          release: 300, rms: true)
        seedDynamics(&values, base: "/lr", preset: mainDynamics, isOn: true)

        return values
    }

    // MARK: - Helpers

    private static func seedLowCut(_ values: inout [String: OSCArgument], base: String, frequency: Float?) {
        values[XR18Params.preamp(base, "hpon")] = .int(frequency == nil ? 0 : 1)
        values[XR18Params.preamp(base, "hpf")] = .float(XR18Params.lowCut.normalized(frequency ?? 80))
    }

    /// Fills every band; bands the preset doesn't use stay flat at spread-out frequencies.
    private static func seedEQ(_ values: inout [String: OSCArgument], base: String, bandCount: Int,
                               preset: EQPreset, isOn: Bool) {
        values[XR18Params.eqOn(base)] = .int(isOn ? 1 : 0)
        let fourBand: [Float] = [100, 400, 2000, 8000]
        let sixBand: [Float] = [60, 150, 400, 1000, 3000, 10000]
        let spread = bandCount == 6 ? sixBand : fourBand
        for index in 0..<bandCount {
            let band = index < preset.bands.count
                ? preset.bands[index]
                : Band(type: index == bandCount - 1 ? .highShelf : .parametric, frequency: spread[index], gain: 0)
            let number = index + 1
            values[XR18Params.eq(base, band: number, "type")] = .int(Int32(band.type.rawValue))
            values[XR18Params.eq(base, band: number, "f")] = .float(XR18Params.eqFrequency.normalized(band.frequency))
            values[XR18Params.eq(base, band: number, "g")] = .float(XR18Params.eqGain.normalized(band.gain))
            values[XR18Params.eq(base, band: number, "q")] = .float(XR18Params.eqQ.normalized(band.q))
        }
    }

    /// Gate settings; `gate/on` itself comes from DemoTransport.
    private static func seedGate(_ values: inout [String: OSCArgument], base: String, isVocal: Bool) {
        values[XR18Params.gate(base, "mode")] = .int(3)
        values[XR18Params.gate(base, "thr")] = .float(XR18Params.gateThreshold.normalized(isVocal ? -52 : -45))
        values[XR18Params.gate(base, "range")] = .float(XR18Params.gateRange.normalized(isVocal ? 20 : 30))
        values[XR18Params.gate(base, "attack")] = .float(XR18Params.gateAttack.normalized(2))
        values[XR18Params.gate(base, "hold")] = .float(XR18Params.gateHold.normalized(50))
        values[XR18Params.gate(base, "release")] = .float(XR18Params.gateRelease.normalized(180))
    }

    /// Dynamics settings; for channels `dyn/on` itself comes from DemoTransport.
    private static func seedDynamics(_ values: inout [String: OSCArgument], base: String,
                                     preset: DynamicsPreset?, isOn: Bool) {
        let dynamics = preset ?? DynamicsPreset(threshold: -20, ratioIndex: 3, knee: 1, makeup: 0,
                                                attack: 15, release: 150)
        let on = XR18Params.dyn(base, "on")
        if !base.hasPrefix("/ch/") { values[on] = .int(isOn ? 1 : 0) }
        values[XR18Params.dyn(base, "mode")] = .int(0)
        values[XR18Params.dyn(base, "det")] = .int(dynamics.rms ? 1 : 0)
        values[XR18Params.dyn(base, "env")] = .int(1)
        values[XR18Params.dyn(base, "thr")] = .float(XR18Params.dynThreshold.normalized(dynamics.threshold))
        values[XR18Params.dyn(base, "ratio")] = .int(dynamics.ratioIndex)
        values[XR18Params.dyn(base, "knee")] = .float(XR18Params.dynKnee.normalized(dynamics.knee))
        values[XR18Params.dyn(base, "mgain")] = .float(XR18Params.dynMakeup.normalized(dynamics.makeup))
        values[XR18Params.dyn(base, "attack")] = .float(XR18Params.dynAttack.normalized(dynamics.attack))
        values[XR18Params.dyn(base, "hold")] = .float(XR18Params.dynHold.normalized(0.02))
        values[XR18Params.dyn(base, "release")] = .float(XR18Params.dynRelease.normalized(dynamics.release))
        values[XR18Params.dyn(base, "mix")] = .float(XR18Params.dynMix.normalized(100))
        values[XR18Params.dyn(base, "auto")] = .int(0)
    }
}
