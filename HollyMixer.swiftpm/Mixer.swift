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
    /// Shown for a moment after an undo, so the volunteer sees what was reverted.
    var undoToast: UndoToast?
    @ObservationIgnored private var removedSendLevels: [String: Float] = [:]
    private static let unityLevel: Float = 0.75
    /// A channel louder than this (dBFS) counts as live: automatic restores wait for it to go quiet.
    static let liveSignalThreshold: Float = -30
    /// Set by the Settings page on iPhone to open the musician setup sheet.
    var showsMonitorSetup = false
    private(set) var host = ""
    private(set) var mixerName = ""
    private(set) var model = ""
    private(set) var firmware = ""
    /// True while talking to the built-in demo mixer instead of real hardware.
    private(set) var isDemo = false
    /// Round trip of the last `/xinfo` ping, in milliseconds.
    private(set) var latency: Int?
    /// True for a Soundcraft Ui mixer (Ui24R, Ui16, Ui12), reached through `Ui24Transport`. It has no gate, EQ,
    /// dynamics or snapshot addresses the app can use yet, so those pages are hidden.
    var isSoundcraft: Bool { model.hasPrefix("Ui") }

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
    /// Names of the mixer's 64 snapshot slots (index 0 = slot 1); empty means unused or not read yet.
    private(set) var snapshotNames = Array(repeating: "", count: 64)
    /// The slot last loaded or saved, as reported by the mixer (`/snap/index`), if known.
    private(set) var currentSnapshot: Int?
    /// "/-snap" is what an XR18 on firmware 1.16 answers to; switches to "/snap" (the official protocol document's
    /// spelling) if that is what the mixer answers to.
    private(set) var snapshotPrefix = "/-snap"
    /// The four DCA groups.
    let dcas = (1...4).map { DCAGroup(number: $0) }
    /// Mute groups 1-4: true when the group is engaged.
    private(set) var muteGroups = [false, false, false, false]
    /// Changes made from this app, newest last.
    private(set) var history: [Change] = []
    /// True once every known parameter has been read from the mixer in this session.
    private(set) var fullStateReady = false
    /// Every value seen or sent in this session, by OSC address (levels, EQ, names…). The settings
    /// backup is made from this.
    @ObservationIgnored private(set) var liveValues: [String: OSCArgument] = [:]
    /// Called after `liveValues` changes (cheap: it only flags the backup as dirty).
    @ObservationIgnored var onValuesChanged: (() -> Void)?
    /// Called once per connection when `fullStateReady` becomes true.
    @ObservationIgnored var onFullState: (() -> Void)?

    /// Strips that feed the mixes: channels 1-16, aux in and FX returns.
    var inputs: [Strip] { channels + [auxIn] + fxReturns }
    var soloedStrips: [Strip] { channels.filter(\.isSoloed) }

    @ObservationIgnored private var connection: MixerTransport = AutoTransport()
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
    @ObservationIgnored private var fullPending: Set<String> = []
    @ObservationIgnored private var fullStateTask: Task<Void, Never>?
    @ObservationIgnored private var fullProgressAt = Date()

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
            use(AutoTransport())
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

    /// Back in front after another app, a lock or a call: iOS may have frozen or closed the UDP socket and the
    /// mixer has stopped sending (its /xremote lease is 10 s). Open a fresh socket, subscribe and read the state again.
    func resumeAfterBackground() {
        guard hasSession, !isDemo, status != .disconnected else { return }
        retryNow()
        subscribe()
        requestState()
    }

    private func start(host: String) {
        self.host = host
        status = .connecting
        hasSession = false
        isSynced = false
        latency = nil
        history = []
        fullStateReady = false
        fullStateTask?.cancel()
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
        connection.send(OSCMessage("/meters", .string("/meters/6")))
    }

    private func requestState() {
        let addresses = allStrips.flatMap(\.syncAddresses) + (1...4).map { "/config/mute/\($0)" }
            + dcas.flatMap(\.syncAddresses) + allStrips.map { "\($0.base)/grp/dca" }
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
        requestFullState()
    }

    /// Every address the settings backup covers: levels, mutes, names, EQ, gate, dynamics, preamp, effects, routing and links.
    var fullStateAddresses: [String] {
        var seen = Set<String>()
        var list: [String] = []
        func add(_ address: String) {
            if !address.hasPrefix("/-stat"), seen.insert(address).inserted { list.append(address) }
        }
        for strip in allStrips {
            strip.syncAddresses.forEach(add)
            XR18Params.detailAddresses(for: strip).forEach(add)
            if strip.isChannel || strip.kind == .auxIn {
                ["config/insrc", "mix/lr"].forEach { add("\(strip.base)/\($0)") }
            }
            if strip.isChannel { add(XR18Params.preamp(strip.base, "rtnsw")) }
        }
        for number in 1...4 { add("/config/mute/\(number)") }
        for group in dcas { group.syncAddresses.forEach(add) }
        for strip in allStrips { add("\(strip.base)/grp/dca"); add("\(strip.base)/grp/mute") }
        Self.globalAddresses.forEach(add)
        return list
    }

    /// Effects, routing and console-wide settings. Each slot's `type` comes before its `par` values, because the
    /// mixer loads the defaults of a type when it changes. Addresses this firmware doesn't answer are ignored.
    static let globalAddresses: [String] = {
        var list: [String] = []
        for slot in 1...4 {
            list.append("/fx/\(slot)/type")
            list += (1...64).map { String(format: "/fx/\(slot)/par/%02d", $0) }
        }
        list += (1...2).map { String(format: "/routing/main/%02d", $0) }
        list += (1...6).map { String(format: "/routing/aux/%02d", $0) }
        list += (1...16).map { String(format: "/routing/p16/%02d", $0) }
        list += ["1-2", "3-4", "5-6", "7-8", "9-10", "11-12", "13-14", "15-16"].map { "/config/chlink/\($0)" }
        list += ["1-2", "3-4", "5-6"].map { "/config/buslink/\($0)" }
        list += ["preamp", "eq", "dyn", "fdrmute"].map { "/config/linkcfg/\($0)" }
        list += ["level", "source", "sourcetrim", "chmode", "busmode", "dcamode", "exclusive", "followsel",
                 "followsolo", "dimatt", "dim", "mono", "delay", "delaytime", "masterctrl", "mute", "dimpfl"]
            .map { "/config/solo/\($0)" }
        return list
    }()

    /// Reads everything the backup needs from the mixer, then reports `fullStateReady`.
    private func requestFullState() {
        fullStateTask?.cancel()
        fullStateTask = Task { [weak self] in
            guard let self else { return }
            // The basic sync already asked for these.
            let basic = Set(allStrips.flatMap(\.syncAddresses))
            let extra = fullStateAddresses.filter { !basic.contains($0) }
            fullPending = Set(extra)
            for (index, address) in extra.enumerated() {
                guard !Task.isCancelled else { return }
                connection.send(OSCMessage(address))
                if index % 8 == 7 { try? await Task.sleep(for: .milliseconds(10)) }
            }
            // UDP can drop a reply, and some addresses don't exist: wait until most have answered, or
            // until replies have stopped for a while, but never longer than 6 s.
            fullProgressAt = Date()
            for _ in 0..<24 {
                if fullPending.count <= extra.count / 50 { break }
                if Date().timeIntervalSince(fullProgressAt) > 1.2 { break }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            fullPending = []
            fullStateReady = true
            onFullState?()
        }
    }

    /// Writes backed-up values to the mixer in small batches. Changes are not added to undo.
    func writeValues(_ values: [(address: String, value: OSCArgument)], progress: ((Int) -> Void)? = nil) async {
        for (index, item) in values.enumerated() {
            route(OSCMessage(item.address, item.value), fromMixer: false)
            connection.send(OSCMessage(item.address, item.value))
            if index % 8 == 7 {
                progress?(index + 1)
                try? await Task.sleep(for: .milliseconds(15))
            }
        }
        progress?(values.count)
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
        case "/meters/6":
            if case .blob(let bytes)? = message.arguments.first {
                handleDynamicsMeters(bytes)
            }
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

    /// `/meters/6` on X AIR (official protocol document): 16 gate, 16 channel dynamics, 6 bus dynamics and Main dynamics
    /// as int16 in 1/256 dB. Values are gain changes, so a reduction is a negative number; shown here as dB of reduction.
    private func handleDynamicsMeters(_ bytes: [UInt8]) {
        guard bytes.count >= 4 else { return }
        func reduction(_ index: Int) -> Float {
            let offset = 4 + index * 2
            guard offset + 1 < bytes.count else { return 0 }
            let raw = Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
            return max(0, -Float(raw) / 256)
        }
        for (index, strip) in channels.enumerated() {
            strip.gateReduction = reduction(index)
            strip.dynReduction = reduction(16 + index)
        }
        for (index, strip) in buses.enumerated() {
            strip.dynReduction = reduction(32 + index)
        }
        main.dynReduction = reduction(38)
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
        record(message.address, message.arguments.first)
        if fromMixer, fullPending.remove(message.address) != nil { fullProgressAt = Date() }
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
        if parts.count == 3, parts[0] == "snap" || parts[0] == "-snap", parts[2] == "name", let slot = Int(parts[1]),
           (1...64).contains(slot), case .string(let value)? = message.arguments.first {
            snapshotNames[slot - 1] = value
            snapshotPrefix = "/" + parts[0]
            return
        }
        if parts.count == 2, parts[0] == "snap" || parts[0] == "-snap", parts[1] == "index",
           case .int(let value)? = message.arguments.first {
            currentSnapshot = Int(value)
            return
        }
        if parts.count >= 3, parts[0] == "dca", let number = Int(parts[1]), (1...4).contains(number) {
            dcas[number - 1].apply(parts[2...].joined(separator: "/"), message.arguments.first)
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

    /// Keeps the newest value of an address for the settings backup.
    private func record(_ address: String, _ value: OSCArgument?) {
        guard let value, !address.hasPrefix("/-stat"), !address.hasPrefix("/meters"),
              !address.hasPrefix("/snap"), !address.hasPrefix("/-snap") else { return }
        switch value {
        case .blob: return
        default: break
        }
        if liveValues[address] != value {
            liveValues[address] = value
            onValuesChanged?()
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
        record(address, .float(value))
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
            return L("\(strip.displayName) fader \(formatDecibels(value)) dB")
        case .send(let index):
            let target: MixTarget = index < 6 ? .bus(index + 1) : .fxSend(index - 5)
            return L("\(strip.displayName) → \(master(for: target).displayName) \(formatDecibels(value)) dB")
        }
    }

    private func sendLevel(_ strip: Strip, _ control: LevelControl) {
        let address = strip.address(control)
        lastSent[address] = Date()
        pendingAddresses.remove(address)
        record(address, .float(strip.level(control)))
        connection.send(OSCMessage(address, .float(strip.level(control))))
    }

    func toggleMute(_ strip: Strip) {
        // A Soundcraft Ui has no Main mute: don't show one that isn't there.
        if isSoundcraft && strip.kind == .main { return }
        let address = "\(strip.base)/mix/on"
        let old = strip.isOn
        strip.isOn.toggle()
        record(address, .int(strip.isOn ? 1 : 0))
        connection.send(OSCMessage(address, .int(strip.isOn ? 1 : 0)))
        record(Change(address: address, old: .int(old ? 1 : 0), new: .int(strip.isOn ? 1 : 0),
                      label: strip.isOn ? L("\(strip.displayName) unmuted") : L("\(strip.displayName) muted")))
    }

    func toggleMuteGroup(_ number: Int) {
        let address = "/config/mute/\(number)"
        let old = muteGroups[number - 1]
        muteGroups[number - 1].toggle()
        let new = muteGroups[number - 1]
        record(address, .int(new ? 1 : 0))
        connection.send(OSCMessage(address, .int(new ? 1 : 0)))
        record(Change(address: address, old: .int(old ? 1 : 0), new: .int(new ? 1 : 0),
                      label: L("Mute group \(number) \(new ? L("on") : L("off"))")))
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

    // MARK: - Mixer snapshots
    // Official protocol (X AIR Remote Control Protocol, fw 1.11+): `/snap/name` and `/snap/index` fill a temporary
    // buffer, `/snap/load N`, `/snap/save N` and `/snap/delete N` act on slot N, `/snap/NN/name` reads or renames
    // a slot. An XR18 on firmware 1.16 answers only to "/-snap" (as in the official app's binary), so both
    // spellings are asked and the one the mixer answers to is used.

    /// Asks the mixer for the names of all 64 snapshot slots.
    func requestSnapshotNames() {
        var addresses = ["/snap/index", "/-snap/index"]
        for prefix in ["/snap", "/-snap"] {
            addresses += (1...64).map { String(format: "\(prefix)/%02d/name", $0) }
        }
        Task {
            for (index, address) in addresses.enumerated() {
                connection.send(OSCMessage(address))
                if index % 8 == 7 { try? await Task.sleep(for: .milliseconds(10)) }
            }
        }
    }

    /// Recalls one of the mixer's own snapshots. Everything the snapshot's recall scope covers changes at once.
    func loadSnapshot(_ slot: Int) {
        guard (1...64).contains(slot) else { return }
        connection.send(OSCMessage("\(snapshotPrefix)/load", .int(Int32(slot))))
        currentSnapshot = slot
        // The mixer pushes the new values; read them again to be sure the screen matches.
        Task {
            try? await Task.sleep(for: .seconds(1))
            requestState()
        }
    }

    /// Stores the current state of the mixer in a snapshot slot. The name (31 characters at most) goes through the
    /// mixer's temporary buffer first, then `save` writes it.
    func saveSnapshot(_ slot: Int, name: String) {
        guard (1...64).contains(slot) else { return }
        let clean = String(name.prefix(31))
        connection.send(OSCMessage("\(snapshotPrefix)/name", .string(clean)))
        connection.send(OSCMessage("\(snapshotPrefix)/save", .int(Int32(slot))))
        snapshotNames[slot - 1] = clean
        currentSnapshot = slot
    }

    /// Empties a snapshot slot.
    func deleteSnapshot(_ slot: Int) {
        guard (1...64).contains(slot) else { return }
        connection.send(OSCMessage("\(snapshotPrefix)/delete", .int(Int32(slot))))
        snapshotNames[slot - 1] = ""
        if currentSnapshot == slot { currentSnapshot = nil }
    }

    // MARK: - Returns in use

    /// A return (bus 1-6) looks in use when its master is up and not muted, and it has its own name or colour or at
    /// least one channel sends to it. The mixer has no "active" flag, so this is read from its own settings.
    func isReturnActive(_ number: Int) -> Bool {
        guard (1...6).contains(number) else { return false }
        let bus = buses[number - 1]
        let send = LevelControl.send(number - 1)
        let hasSends = inputs.contains { $0.hasControl(send) && $0.level(send) > 0.02 }
        return bus.isOn && bus.fader > 0.02 && (bus.isNamed || hasSends)
    }

    // MARK: - DCA groups

    func beginDCA(_ group: DCAGroup, touching: Bool) {
        if touching { beginEdit(group.faderAddress) } else {
            endEdit(group.faderAddress, label: L("\(group.displayName) fader"))
        }
    }

    func setDCALevel(_ group: DCAGroup, to value: Float) {
        setContinuous(group.faderAddress, value)
    }

    func toggleDCAMute(_ group: DCAGroup) {
        let nowOn = !group.isOn
        set(group.onAddress, .int(nowOn ? 1 : 0),
            label: nowOn ? L("\(group.displayName) unmuted") : L("\(group.displayName) muted"))
    }

    /// Which DCAs (bit mask) a strip belongs to. Needs `/…/grp/dca` to have been read.
    func dcaMask(of strip: Strip) -> Int {
        strip.dcaMask
    }

    func setDCAMembership(_ strip: Strip, dca number: Int, member: Bool) {
        var mask = dcaMask(of: strip)
        let bit = 1 << (number - 1)
        mask = member ? (mask | bit) : (mask & ~bit)
        set("\(strip.base)/grp/dca", .int(Int32(mask)),
            label: L("\(strip.displayName) in DCA \(number): \(member ? L("yes") : L("no"))"))
    }

    /// Which mute groups (bit mask, bit 0 = group 1) a strip belongs to. Needs `/…/grp/mute` to have been read.
    func muteGroupMask(of strip: Strip) -> Int {
        strip.muteGroupMask
    }

    func setMuteGroupMembership(_ strip: Strip, group number: Int, member: Bool) {
        var mask = muteGroupMask(of: strip)
        let bit = 1 << (number - 1)
        mask = member ? (mask | bit) : (mask & ~bit)
        set("\(strip.base)/grp/mute", .int(Int32(mask)),
            label: L("\(strip.displayName) in mute group \(number): \(member ? L("yes") : L("no"))"))
    }

    /// How many strips belong to a mute group.
    func muteGroupCount(_ number: Int) -> Int {
        let bit = 1 << (number - 1)
        return allStrips.filter { muteGroupMask(of: $0) & bit != 0 }.count
    }

    /// What silences a strip besides its own MUTE: an active mute group ("G1") or a muted DCA ("DCA2").
    func silencedBy(_ strip: Strip) -> String? {
        let groupMask = muteGroupMask(of: strip)
        for number in 1...4 where groupMask & (1 << (number - 1)) != 0 && muteGroups[number - 1] {
            return "G\(number)"
        }
        let mask = dcaMask(of: strip)
        for group in dcas where mask & (1 << (group.number - 1)) != 0 && !group.isOn {
            return "DCA\(group.number)"
        }
        return nil
    }

    /// In a monitor mix the strip button takes the channel out of that mix (send to -inf) instead of muting the
    /// room. The previous level is kept so a second tap puts it back.
    func isSendRemoved(_ strip: Strip, _ control: LevelControl) -> Bool { strip.level(control) <= 0.001 }

    func toggleSendRemoved(_ strip: Strip, _ control: LevelControl) {
        let key = strip.address(control)
        let level = strip.level(control)
        setTouching(strip, control, true)
        if level > 0.001 {
            removedSendLevels[key] = level
            setLevel(strip, control, to: 0)
        } else {
            setLevel(strip, control, to: removedSendLevels[key] ?? Self.unityLevel)
        }
        setTouching(strip, control, false)
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
    /// Addresses that already have a value are skipped: the mixer pushes later changes through
    /// `/xremote`, and a reconnect re-requests every known address.
    func request(_ addresses: [String]) {
        let addresses = addresses.filter { param($0).value == nil }
        guard !addresses.isEmpty else { return }
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
        undoToast = UndoToast(text: L("Undone: \(change.label)"))
        let message = OSCMessage(change.address, change.old)
        route(message, fromMixer: false)
        connection.send(message)
    }
}

/// A short message after an undo.
struct UndoToast: Equatable, Identifiable {
    let id = UUID()
    let text: String
}

/// Pages shown full screen over the mixer.
enum Screen: Identifiable, Hashable {
    case channel(Strip.Kind)
    case simpleView
    case backups
    case snapshots
    case muteGroups
    case settings
    case help

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
