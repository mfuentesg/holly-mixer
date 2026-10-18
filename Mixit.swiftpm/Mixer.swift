import Foundation
import Network
import Observation
import SwiftUI

/// One fader strip: an input channel or the main LR bus.
@MainActor
@Observable
final class Strip: Identifiable {
    enum Kind: Hashable {
        case channel(Int)
        case main
    }

    let id: Kind
    /// OSC address prefix, e.g. "/ch/01" or "/lr".
    let base: String

    var name = ""
    var colorIndex = 0
    /// Fader position 0...1 as the mixer stores it (0.75 = 0 dB).
    var fader: Float = 0
    /// `mix/on`: true means the strip is NOT muted.
    var isOn = true
    /// Latest meter level in dBFS.
    var meter: Float = -90

    @ObservationIgnored var isTouching = false
    @ObservationIgnored var lastFaderSend = Date.distantPast
    @ObservationIgnored var faderPending = false

    var kind: Kind { id }

    init(kind: Kind) {
        self.id = kind
        switch kind {
        case .channel(let number):
            base = String(format: "/ch/%02d", number)
        case .main:
            base = "/lr"
        }
    }

    var displayName: String {
        if !name.isEmpty { return name }
        switch kind {
        case .channel(let number): return "Ch \(number)"
        case .main: return "Main"
        }
    }

    /// X AIR colour indices 0-7 (8-15 are the same colours, inverted on the mixer's scribble strip).
    static let palette: [Color] = [
        Color(white: 0.35), .red, .green, .yellow, .blue, .pink, .cyan, .white,
    ]

    var color: Color { Strip.palette[colorIndex % 8] }

    var labelTextColor: Color {
        [2, 3, 6, 7].contains(colorIndex % 8) ? .black : .white
    }

    var syncAddresses: [String] {
        ["config/name", "config/color", "mix/fader", "mix/on"].map { "\(base)/\($0)" }
    }

    func apply(_ path: String, _ arguments: [OSCArgument]) {
        switch (path, arguments.first) {
        case ("mix/fader", .float(let value)?):
            if !isTouching { fader = value }
        case ("mix/on", .int(let value)?):
            isOn = value != 0
        case ("config/name", .string(let value)?):
            name = value
        case ("config/color", .int(let value)?):
            colorIndex = Int(value)
        default:
            break
        }
    }
}

/// Mirror of the mixer's state, kept in sync over OSC.
@MainActor
@Observable
final class Mixer {
    enum Status: Equatable {
        case disconnected
        case connecting
        case waitingForNetwork(String)
        case connected
    }

    private(set) var status = Status.disconnected
    /// True once the mixer has answered in this session; the mixer view stays up
    /// across short drop-outs instead of falling back to the connect screen.
    private(set) var hasSession = false
    private(set) var host = ""
    private(set) var mixerName = ""
    private(set) var model = ""
    private(set) var firmware = ""

    let channels: [Strip]
    let main: Strip

    @ObservationIgnored private let connection = MixerConnection()
    @ObservationIgnored private var stripsByBase: [String: Strip] = [:]
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var lastReply = Date.distantPast
    @ObservationIgnored private var transportProblemSince: Date?

    /// Faders are sent at most this often while dragging.
    private static let faderSendInterval: TimeInterval = 0.025
    /// Without any reply (meters arrive ~20 times a second) for this long, the mixer counts as lost.
    private static let replyTimeout: TimeInterval = 3

    init() {
        channels = (1...16).map { Strip(kind: .channel($0)) }
        main = Strip(kind: .main)
        for strip in channels + [main] {
            stripsByBase[strip.base] = strip
        }
        connection.onMessage = { [weak self] message in
            Task { @MainActor in self?.handle(message) }
        }
        connection.onStateChange = { [weak self] state in
            Task { @MainActor in self?.handle(state) }
        }
    }

    // MARK: - Connection

    func connect(host: String) {
        self.host = host
        status = .connecting
        hasSession = false
        lastReply = .distantPast
        transportProblemSince = nil
        connection.connect(host: host)
        startHeartbeat()
    }

    func disconnect() {
        heartbeat?.cancel()
        heartbeat = nil
        connection.disconnect()
        status = .disconnected
        hasSession = false
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                self?.heartbeatTick(tick)
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func heartbeatTick(_ tick: Int) {
        if status == .connected, Date().timeIntervalSince(lastReply) > Self.replyTimeout {
            status = .connecting
        }
        guard status == .connected else {
            // iOS can leave a UDP connection stuck while it asks for Local Network
            // permission; start a fresh one if it hasn't recovered after a few seconds.
            if let since = transportProblemSince, Date().timeIntervalSince(since) > 3 {
                transportProblemSince = nil
                connection.connect(host: host)
            }
            connection.send(OSCMessage("/xinfo"))
            return
        }
        // /xremote and the meter subscription both expire after 10 seconds.
        if tick % 8 == 0 {
            subscribe()
        }
    }

    private func subscribe() {
        connection.send(OSCMessage("/xremote"))
        connection.send(OSCMessage("/meters", .string("/meters/1")))
    }

    private func requestState() {
        let addresses = (channels + [main]).flatMap(\.syncAddresses)
        Task {
            // Small batches so the mixer isn't flooded with a burst of requests.
            for (index, address) in addresses.enumerated() {
                connection.send(OSCMessage(address))
                if index % 8 == 7 {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .waiting(let error), .failed(let error):
            if transportProblemSince == nil { transportProblemSince = Date() }
            if status != .connected && status != .disconnected {
                status = .waitingForNetwork(error.localizedDescription)
            }
        case .ready:
            transportProblemSince = nil
        default:
            break
        }
    }

    // MARK: - Incoming

    private func handle(_ message: OSCMessage) {
        guard status != .disconnected else { return }
        lastReply = Date()
        switch message.address {
        case "/xinfo":
            handleInfo(message.arguments)
        case "/meters/1":
            if case .blob(let bytes)? = message.arguments.first {
                handleMeters(bytes)
            }
        default:
            route(message)
        }
    }

    private func handleInfo(_ arguments: [OSCArgument]) {
        // ,ssss: ip, name, model, firmware
        let strings = arguments.compactMap { argument -> String? in
            if case .string(let value) = argument { return value }
            return nil
        }
        if strings.count >= 4 {
            mixerName = strings[1]
            model = strings[2]
            firmware = strings[3]
        }
        guard status != .connected else { return }
        status = .connected
        hasSession = true
        transportProblemSince = nil
        subscribe()
        requestState()
    }

    /// `/meters/1` on X AIR: 40 int16 values in 1/256 dB, little-endian, after an int32 count:
    /// 16 inputs, 2 aux, 8 FX returns, 6 buses, 4 FX sends, main L/R, monitor L/R.
    private func handleMeters(_ bytes: [UInt8]) {
        guard bytes.count >= 4 else { return }
        let count = Int(Int32(bitPattern: UInt32(bytes[0]) | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24))
        func level(_ index: Int) -> Float? {
            let offset = 4 + index * 2
            guard index < count, offset + 1 < bytes.count else { return nil }
            let raw = Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
            return Float(raw) / 256
        }
        for (index, strip) in channels.enumerated() {
            if let value = level(index) { strip.meter = value }
        }
        if let left = level(36), let right = level(37) {
            main.meter = max(left, right)
        }
    }

    private func route(_ message: OSCMessage) {
        // "/ch/01/mix/fader" -> base "/ch/01", path "mix/fader"; "/lr/mix/on" -> "/lr", "mix/on"
        let parts = message.address.split(separator: "/").map(String.init)
        let base: String
        let path: ArraySlice<String>
        switch parts.first {
        case "ch"? where parts.count > 2:
            base = "/ch/\(parts[1])"
            path = parts[2...]
        case "lr"? where parts.count > 1:
            base = "/lr"
            path = parts[1...]
        default:
            return
        }
        stripsByBase[base]?.apply(path.joined(separator: "/"), message.arguments)
    }

    // MARK: - Outgoing

    func setFader(_ strip: Strip, to value: Float) {
        strip.fader = value
        let now = Date()
        if now.timeIntervalSince(strip.lastFaderSend) >= Self.faderSendInterval {
            sendFader(strip)
        } else {
            strip.faderPending = true
        }
    }

    func setFaderTouching(_ strip: Strip, _ touching: Bool) {
        strip.isTouching = touching
        if !touching && strip.faderPending {
            sendFader(strip)
        }
    }

    private func sendFader(_ strip: Strip) {
        strip.lastFaderSend = Date()
        strip.faderPending = false
        connection.send(OSCMessage("\(strip.base)/mix/fader", .float(strip.fader)))
    }

    func toggleMute(_ strip: Strip) {
        strip.isOn.toggle()
        connection.send(OSCMessage("\(strip.base)/mix/on", .int(strip.isOn ? 1 : 0)))
    }
}

/// X32/X AIR fader taper: position 0...1 to dB (-inf...+10).
func faderToDecibels(_ value: Float) -> Float {
    switch value {
    case 0.5...: return value * 40 - 30
    case 0.25..<0.5: return value * 80 - 50
    case 0.0625..<0.25: return value * 160 - 70
    case ..<0: return -.infinity
    default: return value > 0 ? value * 480 - 90 : -.infinity
    }
}

func formatDecibels(_ value: Float) -> String {
    let db = faderToDecibels(value)
    return db.isFinite ? String(format: "%+.1f", db) : "-∞"
}
