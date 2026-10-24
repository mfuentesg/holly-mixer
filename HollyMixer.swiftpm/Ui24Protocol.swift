import Foundation

/// The Soundcraft Ui12 / Ui16 / Ui24R remote protocol, and how it maps onto the X AIR addresses the rest of the app
/// speaks. The mixer serves a WebSocket on port 80 (`ws://10.10.1.1` on its own "Soundcraft Ui24" Wi-Fi). Every frame
/// starts with "3:::" and may hold several lines separated by "\n":
/// `SETD^i.0.mix^0.75` (a number), `SETS^i.0.name^Vocal` (text), `VU2^<base64>` (meters). The client sends the same
/// `SETD`/`SETS` lines and "ALIVE" every second. On connect the mixer sends its whole state; there is no "get".
/// Source: the open-source soundcraft-ui-connection library (github.com/fmalcher/soundcraft-ui). Verify on hardware.
enum Ui24Protocol {
    static let port: UInt16 = 80
    static let framePrefix = "3:::"
    static let keepalive = "ALIVE"

    enum Line: Equatable {
        case number(key: String, value: Double)
        case text(key: String, value: String)
        case meters([UInt8])
        case other
    }

    /// The lines of one WebSocket frame, or nil when it isn't a "3:::" message.
    static func lines(inFrame frame: String) -> [String]? {
        guard frame.hasPrefix(framePrefix) else { return nil }
        return frame.dropFirst(framePrefix.count).split(whereSeparator: \.isNewline).map(String.init)
    }

    static func parse(_ line: String) -> Line {
        if line.hasPrefix("VU2^") {
            var text = String(line.dropFirst(4))
            text += String(repeating: "=", count: (4 - text.count % 4) % 4)
            return Data(base64Encoded: text).map { .meters([UInt8]($0)) } ?? .other
        }
        let kind = line.prefix(5)
        guard kind == "SETD^" || kind == "SETS^" else { return .other }
        let rest = line.dropFirst(5)
        guard let caret = rest.firstIndex(of: "^") else { return .other }
        let key = String(rest[..<caret])
        let value = String(rest[rest.index(after: caret)...])
        if kind == "SETS^" { return .text(key: key, value: value) }
        return Double(value).map { .number(key: key, value: $0) } ?? .other
    }

    /// One outgoing line, without the "3:::" prefix.
    static func setLine(_ key: String, _ value: UiValue) -> String {
        switch value {
        case .number(let number): return "SETD^\(key)^\(format(number))"
        case .text(let text): return "SETS^\(key)^\(text)"
        }
    }

    private static func format(_ number: Double) -> String {
        if number == number.rounded() && abs(number) < 1e9 { return String(Int(number)) }
        return String(format: "%.6f", number)
    }

    // MARK: - Fader taper

    /// Ui fader position 0...1 to linear gain. A fit of the mixer's own curve (0 = -inf, 1 = +10 dB), from
    /// soundcraft-ui-connection.
    static func faderGain(_ x: Double) -> Double {
        (x < 0.055 ? sin(28.559933214452666 * x) : 1) * exp(curve(x)) * 0.0002676529517952372
    }

    private static func curve(_ x: Double) -> Double {
        (23.90844819639692 + (-26.23877598214595 + (12.195249692570245 - 0.4878099877028098 * x) * x) * x) * x
    }

    /// Derivative of `faderGain`, for the inverse.
    private static func faderGainSlope(_ x: Double) -> Double {
        let slope = 23.90844819639692 + (-52.4775519642919 + (36.58574907771074 - 1.9512399508112392 * x) * x) * x
        let e = exp(curve(x))
        if x < 0.055 {
            let t = 28.559933214452666 * x
            return 0.0002676529517952372 * e * (28.559933214452666 * cos(t) + sin(t) * slope)
        }
        return 0.0002676529517952372 * e * slope
    }

    static func faderToDecibels(_ x: Double) -> Double {
        let gain = faderGain(x)
        return gain < 1e-10 ? -.infinity : 20 * log10(gain)
    }

    static func decibelsToFader(_ db: Double) -> Double {
        if db <= -200 { return 0 }
        if db >= 10 { return 1 }
        let target = pow(10, db / 20)
        var x = 0.5
        for _ in 0..<20 {
            let step = (faderGain(x) - target) / faderGainSlope(x)
            x = min(max(x - step, 1e-10), 1)
            if abs(step) < 1e-15 { break }
        }
        return x
    }

    // MARK: - Models

    /// What each model has (soundcraft-ui-connection's device capabilities).
    struct Model {
        let id: String
        let displayName: String
        let inputs: Int
        let auxes: Int
        let vcas: Int
        /// Preamp gain lives on `hw.N` (Ui24R) or on the input channel `i.N` (Ui12, Ui16).
        let gainPrefix: String
        let gainRange: ClosedRange<Float>

        static let ui24 = Model(id: "ui24", displayName: "Ui24R", inputs: 24, auxes: 10, vcas: 6,
                                gainPrefix: "hw", gainRange: -6...57)
        static let ui16 = Model(id: "ui16", displayName: "Ui16", inputs: 12, auxes: 6, vcas: 0,
                                gainPrefix: "i", gainRange: -40...50)
        static let ui12 = Model(id: "ui12", displayName: "Ui12", inputs: 8, auxes: 4, vcas: 0,
                                gainPrefix: "i", gainRange: -40...50)

        static func named(_ id: String?) -> Model {
            [ui16, ui12].first { $0.id == id } ?? ui24
        }
    }
}

/// A value as the Ui mixer stores it.
enum UiValue: Equatable {
    case number(Double)
    case text(String)

    var numeric: Double? {
        switch self {
        case .number(let value): return value
        case .text(let text): return Double(text)
        }
    }
}

/// How one X AIR address maps to one Ui key.
struct Ui24Binding {
    enum Conversion {
        /// Ui fader taper <-> X AIR fader taper, through dB.
        case fader
        /// The same 0...1 value on both sides (pan).
        case unit
        /// Ui `mute` 1 <-> X AIR `on` 0.
        case muteToOn
        /// 0/1 on both sides (solo, phantom).
        case flag
        case text
        /// Ui preamp gain 0...1 over this dB range <-> X AIR 0...1 over -12...+60 dB.
        case gain(ClosedRange<Float>)
        /// One bit of a Ui mask <-> X AIR 0/1 (mute group on/off).
        case bit(Int)
        /// The lowest bits of a Ui mask <-> an X AIR mask (mute group membership); higher Ui bits are kept.
        case lowBits(Int)
    }

    let key: String
    let conversion: Conversion

    /// The X AIR value for a Ui value.
    func oscValue(_ value: UiValue) -> OSCArgument? {
        if case .text = conversion {
            switch value {
            case .text(let text): return .string(text)
            case .number(let number): return .string(String(number))
            }
        }
        guard let number = value.numeric, number.isFinite else { return nil }
        switch conversion {
        case .fader:
            return .float(decibelsToFader(Float(Ui24Protocol.faderToDecibels(number))))
        case .unit:
            return .float(Float(min(max(number, 0), 1)))
        case .muteToOn:
            return .int(number != 0 ? 0 : 1)
        case .flag:
            return .int(number != 0 ? 1 : 0)
        case .gain(let range):
            let db = range.lowerBound + (range.upperBound - range.lowerBound) * Float(number)
            return .float(XR18Params.preampGain.normalized(db))
        case .bit(let bit):
            return .int(Int32((Int(number) >> bit) & 1))
        case .lowBits(let count):
            return .int(Int32(Int(number) & ((1 << count) - 1)))
        case .text:
            return nil
        }
    }

    /// The Ui value for an X AIR value. `current` is the Ui value now, needed for masks.
    func uiValue(_ argument: OSCArgument, current: UiValue?) -> UiValue? {
        let number: Float
        switch argument {
        case .float(let value): number = value
        case .int(let value): number = Float(value)
        case .string(let text):
            guard case .text = conversion else { return nil }
            // "^" separates fields and a newline separates lines in the protocol.
            return .text(String(text.filter { $0 != "^" && !$0.isNewline }.prefix(31)))
        case .blob: return nil
        }
        let old = current?.numeric.flatMap { $0.isFinite ? Int($0) : nil } ?? 0
        switch conversion {
        case .fader:
            return .number(Ui24Protocol.decibelsToFader(Double(faderToDecibels(number))))
        case .unit:
            return .number(Double(min(max(number, 0), 1)))
        case .muteToOn:
            return .number(number != 0 ? 0 : 1)
        case .flag:
            return .number(number != 0 ? 1 : 0)
        case .gain(let range):
            let db = XR18Params.preampGain.value(number)
            let span = range.upperBound - range.lowerBound
            return .number(Double(min(max((db - range.lowerBound) / span, 0), 1)))
        case .bit(let bit):
            return .number(Double(number != 0 ? old | (1 << bit) : old & ~(1 << bit)))
        case .lowBits(let count):
            let mask = (1 << count) - 1
            return .number(Double((old & ~mask) | (Int(number) & mask)))
        case .text:
            return nil
        }
    }
}

/// Every X AIR address the app uses that a Ui mixer has, and the reverse lookup.
struct Ui24Map {
    let model: Ui24Protocol.Model
    let bindings: [String: Ui24Binding]
    /// Ui key -> X AIR addresses that read it.
    let addressesByKey: [String: [String]]

    /// X AIR addresses with no Ui counterpart that still get a fixed answer, so the screen shows something sensible:
    /// the Ui has no Main mute and no FX send masters.
    static let fixedValues: [String: OSCArgument] = {
        var values: [String: OSCArgument] = ["/lr/mix/on": .int(1)]
        for number in 1...4 {
            values["/fxsend/\(number)/mix/fader"] = .float(0.75)
            values["/fxsend/\(number)/mix/on"] = .int(1)
        }
        return values
    }()

    init(model: Ui24Protocol.Model) {
        self.model = model
        let buses = min(6, model.auxes)
        var bindings: [String: Ui24Binding] = [:]
        var addressesByKey: [String: [String]] = [:]

        func bind(_ address: String, _ key: String, _ conversion: Ui24Binding.Conversion) {
            bindings[address] = Ui24Binding(key: key, conversion: conversion)
            addressesByKey[key, default: []].append(address)
        }

        func strip(_ osc: String, _ ui: String, pan: Bool = true) {
            bind("\(osc)/mix/fader", "\(ui).mix", .fader)
            bind("\(osc)/mix/on", "\(ui).mute", .muteToOn)
            bind("\(osc)/config/name", "\(ui).name", .text)
            if pan { bind("\(osc)/mix/pan", "\(ui).pan", .unit) }
        }
        func sends(_ osc: String, _ ui: String, fx: Bool) {
            for bus in 0..<buses {
                bind("\(osc)/\(LevelControl.send(bus).path)", "\(ui).aux.\(bus).value", .fader)
            }
            guard fx else { return }
            for slot in 0..<4 {
                bind("\(osc)/\(LevelControl.send(6 + slot).path)", "\(ui).fx.\(slot).value", .fader)
            }
        }

        for number in 1...min(16, model.inputs) {
            let osc = String(format: "/ch/%02d", number)
            let ui = "i.\(number - 1)"
            strip(osc, ui)
            sends(osc, ui, fx: true)
            bind("\(osc)/grp/mute", "\(ui).mgmask", .lowBits(4))
            bind(String(format: "/-stat/solosw/%02d", number), "\(ui).solo", .flag)
            let hw = "\(model.gainPrefix).\(number - 1)"
            bind(XR18Params.headamp(number, "gain"), "\(hw).gain", .gain(model.gainRange))
            bind(XR18Params.headamp(number, "phantom"), "\(hw).phantom", .flag)
        }
        // The stereo line input stands in for the X AIR aux input.
        strip("/rtn/aux", "l.0")
        sends("/rtn/aux", "l.0", fx: true)
        for number in 1...4 {
            strip("/rtn/\(number)", "f.\(number - 1)", pan: false)
            sends("/rtn/\(number)", "f.\(number - 1)", fx: false)
        }
        for number in 1...buses {
            strip("/bus/\(number)", "a.\(number - 1)", pan: false)
        }
        bind("/lr/mix/fader", "m.mix", .fader)
        bind("/lr/mix/pan", "m.pan", .unit)
        for number in 0..<min(4, model.vcas) {
            bind("/dca/\(number + 1)/fader", "v.\(number).mix", .fader)
            bind("/dca/\(number + 1)/on", "v.\(number).mute", .muteToOn)
            bind("/dca/\(number + 1)/config/name", "v.\(number).name", .text)
        }
        for number in 0..<4 {
            bind("/config/mute/\(number + 1)", "mgmask", .bit(number))
        }
        self.bindings = bindings
        self.addressesByKey = addressesByKey
    }

    /// The other half of a stereo-linked input, which the Ui mixer expects the client to move too
    /// (`i.N.stereoIndex` is 0 on the left channel and 1 on the right, -1 when not linked).
    static func linkedKey(_ key: String, stereoIndex: (String) -> Double?) -> String? {
        let parts = key.split(separator: ".", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "i" || parts[0] == "l", let number = Int(parts[1]) else { return nil }
        let field = parts[2]
        let follows = ["mix", "mute", "solo"].contains(field)
            || (field.hasPrefix("aux.") || field.hasPrefix("fx.")) && field.hasSuffix(".value")
        guard follows, let index = stereoIndex("\(parts[0]).\(number).stereoIndex") else { return nil }
        switch index {
        case 0: return "\(parts[0]).\(number + 1).\(field)"
        case 1 where number > 0: return "\(parts[0]).\(number - 1).\(field)"
        default: return nil
        }
    }

    // MARK: - Meters

    /// Turns a Ui `VU2` frame into an X AIR `/meters/1` blob (int32 count, then 40 little-endian int16 levels in
    /// 1/256 dB: 16 inputs, aux L/R, 4 stereo FX returns, 6 buses, 4 FX sends, main L/R, monitor L/R).
    /// `VU2` starts with 8 counts (inputs, players, subgroups, FX, auxes, masters, line inputs), then a block per
    /// strip; a level byte times 0.004167508 is 0...1 over -80...0 dB.
    static func xairMeters(fromVU bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count >= 8 else { return nil }
        let blockSizes = [6, 6, 7, 7, 5, 5, 6]
        var blockStarts: [[Int]] = []
        var offset = 8
        for (index, size) in blockSizes.enumerated() {
            blockStarts.append((0..<Int(bytes[index])).map { offset + $0 * size })
            offset += Int(bytes[index]) * size
        }
        func level(_ group: Int, _ strip: Int, _ field: Int) -> Float? {
            guard strip < blockStarts[group].count else { return nil }
            let position = blockStarts[group][strip] + field
            guard position < bytes.count else { return nil }
            let value = min(Float(bytes[position]) * 0.004167508166392142, 1)
            return value <= 0 ? -90 : value * 80 - 80
        }
        let input = 0, fx = 3, aux = 4, master = 5, line = 6
        var levels = [Float](repeating: -90, count: 40)
        func put(_ index: Int, _ value: Float?) {
            if let value { levels[index] = value }
        }
        for strip in 0..<16 { put(strip, level(input, strip, 1)) }            // post-processing, pre-fader
        put(16, level(line, 0, 1))
        put(17, level(line, 1, 1) ?? level(line, 0, 1))
        for strip in 0..<4 {
            put(18 + strip * 2, level(fx, strip, 2))                         // post-fader L
            put(19 + strip * 2, level(fx, strip, 3))                         // post-fader R
        }
        for strip in 0..<6 { put(26 + strip, level(aux, strip, 1)) }          // post-fader
        put(36, level(master, 0, 1))
        put(37, level(master, 1, 1) ?? level(master, 0, 1))

        var blob = [UInt8]()
        withUnsafeBytes(of: UInt32(levels.count).littleEndian) { blob.append(contentsOf: $0) }
        for value in levels {
            let raw = UInt16(bitPattern: Int16(max(min(value, 0), -128) * 256))
            withUnsafeBytes(of: raw.littleEndian) { blob.append(contentsOf: $0) }
        }
        return blob
    }
}
