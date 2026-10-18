import Foundation
import Network
import Observation

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

    /// The mix the faders currently control.
    var selectedMix = MixTarget.main

    let channels: [Strip]
    let auxIn: Strip
    let fxReturns: [Strip]
    let buses: [Strip]
    let fxSends: [Strip]
    let main: Strip

    /// Strips that feed the mixes: channels 1-16, aux in and FX returns.
    var inputs: [Strip] { channels + [auxIn] + fxReturns }

    @ObservationIgnored private let connection = MixerConnection()
    @ObservationIgnored private var stripsByBase: [String: Strip] = [:]
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var lastReply = Date.distantPast
    @ObservationIgnored private var transportProblemSince: Date?
    /// Addresses under the user's finger; incoming updates for them are ignored.
    @ObservationIgnored private var touchedAddresses: Set<String> = []
    @ObservationIgnored private var lastSent: [String: Date] = [:]
    @ObservationIgnored private var pendingAddresses: Set<String> = []

    /// Levels are sent at most this often while dragging.
    private static let levelSendInterval: TimeInterval = 0.025
    /// Without any reply (meters arrive ~20 times a second) for this long, the mixer counts as lost.
    private static let replyTimeout: TimeInterval = 3

    init() {
        channels = (1...16).map { Strip(kind: .channel($0)) }
        auxIn = Strip(kind: .auxIn)
        fxReturns = (1...4).map { Strip(kind: .fxReturn($0)) }
        buses = (1...6).map { Strip(kind: .bus($0)) }
        fxSends = (1...4).map { Strip(kind: .fxSend($0)) }
        main = Strip(kind: .main)
        for strip in allStrips {
            stripsByBase[strip.base] = strip
        }
        connection.onMessage = { [weak self] message in
            Task { @MainActor in self?.handle(message) }
        }
        connection.onStateChange = { [weak self] state in
            Task { @MainActor in self?.handle(state) }
        }
    }

    private var allStrips: [Strip] { inputs + buses + fxSends + [main] }

    /// The master strip of a mix: Main LR, a bus or an FX send.
    func master(for target: MixTarget) -> Strip {
        switch target {
        case .main: return main
        case .bus(let number): return buses[number - 1]
        case .fxSend(let number): return fxSends[number - 1]
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
        let addresses = allStrips.flatMap(\.syncAddresses)
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
    /// 16 inputs, aux L/R, 4 stereo FX returns, 6 buses, 4 FX sends, main L/R, monitor L/R.
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
        func stereo(_ index: Int) -> Float? {
            guard let left = level(index), let right = level(index + 1) else { return nil }
            return max(left, right)
        }
        for (index, strip) in channels.enumerated() {
            if let value = level(index) { strip.meter = value }
        }
        if let value = stereo(16) { auxIn.meter = value }
        for (index, strip) in fxReturns.enumerated() {
            if let value = stereo(18 + index * 2) { strip.meter = value }
        }
        for (index, strip) in buses.enumerated() {
            if let value = level(26 + index) { strip.meter = value }
        }
        for (index, strip) in fxSends.enumerated() {
            if let value = level(32 + index) { strip.meter = value }
        }
        if let value = stereo(36) { main.meter = value }
    }

    private func route(_ message: OSCMessage) {
        guard !touchedAddresses.contains(message.address) else { return }
        // "/ch/01/mix/fader" -> base "/ch/01", path "mix/fader"; "/lr/mix/on" -> "/lr", "mix/on"
        let parts = message.address.split(separator: "/").map(String.init)
        let base: String
        let path: ArraySlice<String>
        if parts.first == "lr", parts.count > 1 {
            base = "/lr"
            path = parts[1...]
        } else if parts.count > 2 {
            base = "/\(parts[0])/\(parts[1])"
            path = parts[2...]
        } else {
            return
        }
        stripsByBase[base]?.apply(path.joined(separator: "/"), message.arguments)
    }

    // MARK: - Outgoing

    func setLevel(_ strip: Strip, _ control: LevelControl, to value: Float) {
        strip.setLevel(value, for: control)
        let address = strip.address(control)
        if Date().timeIntervalSince(lastSent[address] ?? .distantPast) >= Self.levelSendInterval {
            sendLevel(strip, control)
        } else {
            pendingAddresses.insert(address)
        }
    }

    func setTouching(_ strip: Strip, _ control: LevelControl, _ touching: Bool) {
        let address = strip.address(control)
        if touching {
            touchedAddresses.insert(address)
        } else {
            touchedAddresses.remove(address)
            if pendingAddresses.contains(address) {
                sendLevel(strip, control)
            }
        }
    }

    private func sendLevel(_ strip: Strip, _ control: LevelControl) {
        let address = strip.address(control)
        lastSent[address] = Date()
        pendingAddresses.remove(address)
        connection.send(OSCMessage(address, .float(strip.level(control))))
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
