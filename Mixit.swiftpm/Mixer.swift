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

    /// One undoable change made from this app.
    struct Change: Identifiable {
        let id = UUID()
        let address: String
        let old: OSCArgument
        let new: OSCArgument
        let label: String
        let date = Date()
    }

    private(set) var status = Status.disconnected
    /// True once the mixer has answered in this session; the mixer view stays up
    /// across short drop-outs instead of falling back to the connect screen.
    private(set) var hasSession = false
    private(set) var host = ""
    private(set) var mixerName = ""
    private(set) var model = ""
    private(set) var firmware = ""
    /// True while talking to the built-in demo mixer instead of real hardware.
    private(set) var isDemo = false
    /// Round trip of the last `/xinfo` ping, in milliseconds.
    private(set) var latency: Int?

    /// The mix the faders currently control.
    var selectedMix = MixTarget.main
    /// The strip highlighted for editing.
    var selectedStrip: Strip.Kind? = .channel(1)
    /// Full-screen page shown over the mixer (channel detail, scenes, Service Mode…).
    var presentedScreen: Screen?

    let channels: [Strip]
    let auxIn: Strip
    let fxReturns: [Strip]
    let buses: [Strip]
    let fxSends: [Strip]
    let main: Strip
    /// Mute groups 1-4: true when the group is engaged.
    private(set) var muteGroups = [false, false, false, false]
    /// Changes made from this app, newest last.
    private(set) var history: [Change] = []

    /// Strips that feed the mixes: channels 1-16, aux in and FX returns.
    var inputs: [Strip] { channels + [auxIn] + fxReturns }
    var soloedStrips: [Strip] { channels.filter(\.isSoloed) }

    @ObservationIgnored private var connection: MixerTransport = MixerConnection()
    @ObservationIgnored private var stripsByBase: [String: Strip] = [:]
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var lastReply = Date.distantPast
    @ObservationIgnored private var transportProblemSince: Date?
    /// Addresses under the user's finger; incoming updates for them are ignored.
    @ObservationIgnored private var touchedAddresses: Set<String> = []
    @ObservationIgnored private var touchStartValues: [String: Float] = [:]
    @ObservationIgnored private var lastSent: [String: Date] = [:]
    @ObservationIgnored private var pendingAddresses: Set<String> = []
    @ObservationIgnored private var pingSentAt: Date?
    /// Set once the initial sync is done, so the sync itself doesn't flash every strip.
    @ObservationIgnored private var isSynced = false
    @ObservationIgnored private var flashGeneration: [Strip.Kind: Int] = [:]
    /// Observable values for any other OSC address (EQ, dynamics, preamp…), created on demand.
    @ObservationIgnored private var params: [String: Param] = [:]
    @ObservationIgnored private var editStartValues: [String: OSCArgument] = [:]

    /// Levels are sent at most this often while dragging.
    private static let levelSendInterval: TimeInterval = 0.025
    /// Without any reply (meters arrive ~20 times a second) for this long, the mixer counts as lost.
    private static let replyTimeout: TimeInterval = 3
    private static let historyLimit = 100

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
        use(connection)
    }

    private func use(_ transport: MixerTransport) {
        connection.disconnect()
        connection = transport
        transport.onMessage = { [weak self] message in
            Task { @MainActor in self?.handle(message) }
        }
        transport.onStateChange = { [weak self] state in
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

    func strip(_ kind: Strip.Kind) -> Strip? {
        allStrips.first { $0.kind == kind }
    }

    // MARK: - Connection

    func connect(host: String) {
        if isDemo {
            use(MixerConnection())
        }
        isDemo = false
        start(host: host)
    }

    /// Connects to the built-in demo mixer, for trying the app without hardware.
    func startDemo() {
        use(DemoTransport())
        isDemo = true
        start(host: "demo")
    }

    /// Starts a fresh connection to the same mixer, e.g. from the "Retry now" button.
    func retryNow() {
        guard !isDemo else { return }
        transportProblemSince = nil
        connection.connect(host: host)
        connection.send(OSCMessage("/xinfo"))
    }

    private func start(host: String) {
        self.host = host
        status = .connecting
        hasSession = false
        isSynced = false
        latency = nil
        history = []
        selectedMix = .main
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
        if tick % 2 == 0 {
            pingSentAt = Date()
            connection.send(OSCMessage("/xinfo"))
        }
    }

    private func subscribe() {
        connection.send(OSCMessage("/xremote"))
        connection.send(OSCMessage("/meters", .string("/meters/1")))
    }

    private func requestState() {
        let addresses = allStrips.flatMap(\.syncAddresses) + (1...4).map { "/config/mute/\($0)" }
            + params.keys.sorted()
        Task {
            // Small batches so the mixer isn't flooded with a burst of requests.
            for (index, address) in addresses.enumerated() {
                connection.send(OSCMessage(address))
                if index % 8 == 7 {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            try? await Task.sleep(for: .seconds(1))
            isSynced = true
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
            route(message, fromMixer: true)
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
        if let pingSentAt {
            latency = max(1, Int(Date().timeIntervalSince(pingSentAt) * 1000))
            self.pingSentAt = nil
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
        func setStereo(_ strip: Strip, _ index: Int) {
            if let left = level(index), let right = level(index + 1) {
                strip.setMeter(left, right: right)
            }
        }
        for (index, strip) in channels.enumerated() {
            if let value = level(index) { strip.setMeter(value) }
        }
        setStereo(auxIn, 16)
        for (index, strip) in fxReturns.enumerated() {
            setStereo(strip, 18 + index * 2)
        }
        for (index, strip) in buses.enumerated() {
            if let value = level(26 + index) { strip.setMeter(value) }
        }
        for (index, strip) in fxSends.enumerated() {
            if let value = level(32 + index) { strip.setMeter(value) }
        }
        setStereo(main, 36)
    }

    /// Applies a message to the local state. Messages from the mixer for a control under
    /// the user's finger are ignored, and changes made elsewhere make the strip flash.
    private func route(_ message: OSCMessage, fromMixer: Bool) {
        if fromMixer && touchedAddresses.contains(message.address) { return }
        if let param = params[message.address], let value = message.arguments.first {
            param.value = value
        }
        let parts = message.address.split(separator: "/").map(String.init)
        if parts.count == 3, parts[0] == "config", parts[1] == "mute",
           let number = Int(parts[2]), (1...4).contains(number), case .int(let value)? = message.arguments.first {
            muteGroups[number - 1] = value != 0
            return
        }
        if parts.count == 3, parts[0] == "-stat", parts[1] == "solosw",
           let number = Int(parts[2]), (1...16).contains(number), case .int(let value)? = message.arguments.first {
            channels[number - 1].isSoloed = value != 0
            return
        }
        // "/ch/01/mix/fader" -> base "/ch/01", path "mix/fader"; "/lr/mix/on" -> "/lr", "mix/on"
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
        guard let strip = stripsByBase[base] else { return }
        let changed = strip.apply(path.joined(separator: "/"), message.arguments)
        if changed && fromMixer && isSynced {
            flash(strip)
        }
    }

    private func flash(_ strip: Strip) {
        let generation = (flashGeneration[strip.kind] ?? 0) + 1
        flashGeneration[strip.kind] = generation
        strip.changedElsewhere = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if flashGeneration[strip.kind] == generation {
                strip.changedElsewhere = false
            }
        }
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
            touchStartValues[address] = strip.level(control)
        } else {
            touchedAddresses.remove(address)
            if pendingAddresses.contains(address) {
                sendLevel(strip, control)
            }
            let new = strip.level(control)
            if let old = touchStartValues.removeValue(forKey: address), old != new {
                record(Change(address: address, old: .float(old), new: .float(new),
                              label: levelLabel(strip, control, new)))
            }
        }
    }

    private func levelLabel(_ strip: Strip, _ control: LevelControl, _ value: Float) -> String {
        switch control {
        case .fader:
            return "\(strip.displayName) fader \(formatDecibels(value)) dB"
        case .send(let index):
            let target: MixTarget = index < 6 ? .bus(index + 1) : .fxSend(index - 5)
            return "\(strip.displayName) → \(master(for: target).displayName) \(formatDecibels(value)) dB"
        }
    }

    private func sendLevel(_ strip: Strip, _ control: LevelControl) {
        let address = strip.address(control)
        lastSent[address] = Date()
        pendingAddresses.remove(address)
        connection.send(OSCMessage(address, .float(strip.level(control))))
    }

    func toggleMute(_ strip: Strip) {
        let address = "\(strip.base)/mix/on"
        let old = strip.isOn
        strip.isOn.toggle()
        connection.send(OSCMessage(address, .int(strip.isOn ? 1 : 0)))
        record(Change(address: address, old: .int(old ? 1 : 0), new: .int(strip.isOn ? 1 : 0),
                      label: "\(strip.displayName) \(strip.isOn ? "unmuted" : "muted")"))
    }

    func toggleMuteGroup(_ number: Int) {
        let address = "/config/mute/\(number)"
        let old = muteGroups[number - 1]
        muteGroups[number - 1].toggle()
        let new = muteGroups[number - 1]
        connection.send(OSCMessage(address, .int(new ? 1 : 0)))
        record(Change(address: address, old: .int(old ? 1 : 0), new: .int(new ? 1 : 0),
                      label: "Mute group \(number) \(new ? "on" : "off")"))
    }

    func toggleSolo(_ strip: Strip) {
        guard let address = strip.soloAddress else { return }
        strip.isSoloed.toggle()
        connection.send(OSCMessage(address, .int(strip.isSoloed ? 1 : 0)))
    }

    func clearSolo() {
        for strip in soloedStrips {
            toggleSolo(strip)
        }
    }

    // MARK: - Any parameter

    /// The observable value of an OSC address, e.g. "/ch/01/eq/1/f". Ask the mixer for it with `request`.
    func param(_ address: String) -> Param {
        if let param = params[address] { return param }
        let param = Param(address: address)
        params[address] = param
        return param
    }

    /// Asks the mixer for the current values of these addresses (answers update their `Param`s).
    func request(_ addresses: [String]) {
        for address in addresses {
            _ = param(address)
        }
        Task {
            for (index, address) in addresses.enumerated() {
                connection.send(OSCMessage(address))
                if index % 8 == 7 {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        }
    }

    /// Sets a parameter once (a switch, a picker). With a `label` the change can be undone.
    func set(_ address: String, _ value: OSCArgument, label: String? = nil) {
        let param = param(address)
        let old = param.value
        route(OSCMessage(address, value), fromMixer: false)
        connection.send(OSCMessage(address, value))
        if let label, let old, old != value {
            record(Change(address: address, old: old, new: value, label: label))
        }
    }

    /// Call when a finger starts dragging a continuous control (knob, EQ node).
    /// Incoming values for it are ignored until `endEdit`.
    func beginEdit(_ address: String) {
        touchedAddresses.insert(address)
        editStartValues[address] = param(address).value
    }

    /// Sends a continuous value while dragging, at most every 25 ms.
    func setContinuous(_ address: String, _ value: Float) {
        _ = param(address)
        route(OSCMessage(address, .float(value)), fromMixer: false)
        if Date().timeIntervalSince(lastSent[address] ?? .distantPast) >= Self.levelSendInterval {
            lastSent[address] = Date()
            pendingAddresses.remove(address)
            connection.send(OSCMessage(address, .float(value)))
        } else {
            pendingAddresses.insert(address)
        }
    }

    /// Call when the finger lifts: sends the final value and records one undo step.
    func endEdit(_ address: String, label: String) {
        touchedAddresses.remove(address)
        let param = param(address)
        if pendingAddresses.remove(address) != nil, let value = param.value {
            lastSent[address] = Date()
            connection.send(OSCMessage(address, value))
        }
        if let old = editStartValues.removeValue(forKey: address), let new = param.value, old != new {
            record(Change(address: address, old: old, new: new, label: label))
        }
    }

    // MARK: - Undo

    private func record(_ change: Change) {
        history.append(change)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
    }

    /// Reverts the newest change made from this app.
    func undo() {
        guard let change = history.popLast() else { return }
        let message = OSCMessage(change.address, change.old)
        route(message, fromMixer: false)
        connection.send(message)
    }
}

/// Pages shown full screen over the mixer.
enum Screen: Identifiable, Hashable {
    case channel(Strip.Kind)
    case scenes
    case serviceMode
    case serviceEditor
    case monitorPairing

    var id: Self { self }
}

/// The value of one OSC address, observable by views.
@MainActor
@Observable
final class Param {
    let address: String
    var value: OSCArgument?

    init(address: String) {
        self.address = address
    }

    var float: Float? {
        if case .float(let value)? = value { return value }
        return nil
    }

    var int: Int? {
        if case .int(let value)? = value { return Int(value) }
        return nil
    }

    var string: String? {
        if case .string(let value)? = value { return value }
        return nil
    }

    var bool: Bool? { int.map { $0 != 0 } }
}

/// X32/X AIR fader taper: position 0...1 to dB (-inf...+10).
func faderToDecibels(_ value: Float) -> Float {
    if value >= 0.5 { return value * 40 - 30 }
    if value >= 0.25 { return value * 80 - 50 }
    if value >= 0.0625 { return value * 160 - 70 }
    if value > 0 { return value * 480 - 90 }
    return -.infinity
}

/// Inverse of `faderToDecibels`: dB to fader position 0...1.
func decibelsToFader(_ db: Float) -> Float {
    if db >= -10 { return min((db + 30) / 40, 1) }
    if db >= -30 { return (db + 50) / 80 }
    if db >= -60 { return (db + 70) / 160 }
    return max((db + 90) / 480, 0)
}

/// "+7.8", "−3.0", "−∞" (true minus sign, as in the design).
func formatDecibels(_ value: Float) -> String {
    let db = faderToDecibels(value)
    guard db.isFinite, db > -89.95 else { return "−∞" }
    let text = String(format: "%.1f", abs(db))
    if text == "0.0" { return "0.0" }
    return (db > 0 ? "+" : "−") + text
}
