import Foundation
import Network

/// An in-app stand-in for the church's XR18, for trying Mixit without the mixer.
/// It answers queries like the real mixer, remembers changes, and sends animated meters.
/// Channel names, colours, faders and mutes match the mixer as it was on 18 Oct 2026.
final class DemoTransport: MixerTransport {
    var onMessage: ((OSCMessage) -> Void)?
    var onStateChange: ((NWConnection.State) -> Void)?

    private var values = DemoTransport.initialState()
    private var meterTask: Task<Void, Never>?

    func connect(host: String) {
        onStateChange?(.ready)
    }

    func disconnect() {
        meterTask?.cancel()
        meterTask = nil
    }

    func send(_ message: OSCMessage) {
        switch message.address {
        case "/xinfo":
            onMessage?(OSCMessage("/xinfo", .string("demo"), .string("XR18-C3-D7-F9"),
                                  .string("XR18"), .string("1.16")))
        case "/xremote":
            break
        case "/meters":
            startMeters()
        default:
            if let value = message.arguments.first {
                // A change: remember it (the real mixer doesn't echo it back to the sender).
                values[message.address] = value
            } else if let value = values[message.address] {
                onMessage?(OSCMessage(message.address, value))
            }
        }
    }

    // MARK: - Initial state

    private struct DemoChannel {
        let name: String
        let color: Int32
        let db: Float
        let isOn: Bool
        /// Typical pre-fader signal level in dBFS, or nil for no signal.
        let signal: Float?
    }

    // X AIR colours: 1 red, 3 yellow, 6 cyan.
    private static let channels: [DemoChannel] = [
        DemoChannel(name: "Pulpito", color: 3, db: 7.8, isOn: true, signal: -22),
        DemoChannel(name: "Mic Oscar", color: 3, db: 6.9, isOn: false, signal: -20),
        DemoChannel(name: "Guitarra Acus", color: 6, db: 0.7, isOn: false, signal: -16),
        DemoChannel(name: "Bajo", color: 6, db: -3.0, isOn: false, signal: -14),
        DemoChannel(name: "Mic Martin", color: 3, db: 7.3, isOn: false, signal: -20),
        DemoChannel(name: "Mic Cata", color: 3, db: 6.0, isOn: false, signal: -21),
        DemoChannel(name: "Voz Off", color: 1, db: -.infinity, isOn: false, signal: -30),
        DemoChannel(name: "Guit Marcelo", color: 6, db: -8.5, isOn: false, signal: -17),
        DemoChannel(name: "Martín", color: 6, db: -1.7, isOn: false, signal: -19),
        DemoChannel(name: "Batería", color: 6, db: 0.7, isOn: false, signal: -12),
        DemoChannel(name: "Maxi", color: 6, db: -6.0, isOn: false, signal: -18),
        DemoChannel(name: "", color: 0, db: -.infinity, isOn: false, signal: nil),
        DemoChannel(name: "", color: 0, db: -.infinity, isOn: true, signal: nil),
        DemoChannel(name: "", color: 0, db: -.infinity, isOn: true, signal: nil),
        DemoChannel(name: "", color: 0, db: -.infinity, isOn: true, signal: nil),
        DemoChannel(name: "", color: 0, db: -.infinity, isOn: true, signal: nil),
    ]

    private static func initialState() -> [String: OSCArgument] {
        var values: [String: OSCArgument] = [:]

        func strip(_ base: String, name: String, color: Int32, db: Float, isOn: Bool, sends: Int) {
            values["\(base)/config/name"] = .string(name)
            values["\(base)/config/color"] = .int(color)
            values["\(base)/mix/fader"] = .float(decibelsToFader(db))
            values["\(base)/mix/on"] = .int(isOn ? 1 : 0)
            for send in 0..<sends {
                // Varied but repeatable monitor send levels between -20 and 0 dB.
                let db = Float((base.hashValueStable + send * 7) % 21) - 20
                values["\(base)/\(LevelControl.send(send).path)"] = .float(decibelsToFader(db))
            }
        }

        for (index, channel) in channels.enumerated() {
            strip(String(format: "/ch/%02d", index + 1), name: channel.name, color: channel.color,
                  db: channel.db, isOn: channel.isOn, sends: 10)
        }
        strip("/rtn/aux", name: "", color: 0, db: -10, isOn: true, sends: 10)
        for number in 1...4 {
            strip("/rtn/\(number)", name: "", color: 0, db: -10, isOn: true, sends: 6)
        }
        for number in 1...6 {
            strip("/bus/\(number)", name: "", color: 0, db: 0, isOn: true, sends: 0)
        }
        for number in 1...4 {
            strip("/fxsend/\(number)", name: "", color: 0, db: 0, isOn: true, sends: 0)
        }
        strip("/lr", name: "", color: 0, db: -1.5, isOn: true, sends: 0)
        return values
    }

    // MARK: - Meters

    private func startMeters() {
        guard meterTask == nil else { return }
        meterTask = Task { [weak self] in
            var time = 0.0
            while !Task.isCancelled {
                self?.sendMeters(time: time)
                time += 0.05
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Same layout as the XR18's `/meters/1`: 16 inputs, aux L/R, 4 stereo FX returns,
    /// 6 buses, 4 FX sends, main L/R, monitor L/R.
    private func sendMeters(time: Double) {
        var levels = [Float](repeating: -90, count: 40)
        for (index, channel) in Self.channels.enumerated() {
            if let signal = channel.signal {
                levels[index] = Self.animated(signal, time: time, seed: index)
            }
        }
        levels[16] = Self.animated(-26, time: time, seed: 16)
        levels[17] = levels[16] - 1
        for index in 18..<26 {
            levels[index] = Self.animated(-30, time: time, seed: index / 2)
        }
        for index in 26..<36 {
            levels[index] = Self.animated(-18, time: time, seed: index)
        }
        for index in 36..<40 {
            levels[index] = Self.animated(-14, time: time, seed: 40 + index / 2)
        }

        var bytes = [UInt8]()
        appendLittleEndian(UInt32(levels.count), to: &bytes)
        for level in levels {
            let raw = Int16(max(min(level, 0), -128) * 256)
            appendLittleEndian(UInt16(bitPattern: raw), to: &bytes)
        }
        onMessage?(OSCMessage("/meters/1", .blob(bytes)))
    }

    /// Phrase-like movement around a base level: a slow swell plus a little flutter.
    private static func animated(_ base: Float, time: Double, seed: Int) -> Float {
        let t = time + Double(seed) * 1.7
        let swell = (sin(t * 0.8) + sin(t * 2.3 + Double(seed))) / 2
        return base + Float(swell) * 8 + Float.random(in: -2...2)
    }

    private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }
}

private extension String {
    /// A hash that is the same on every launch (Swift's `hashValue` is randomly seeded).
    var hashValueStable: Int {
        unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
    }
}
