import Foundation
import Network

/// WebSocket transport to a Soundcraft Ui mixer (Ui24R, Ui16, Ui12). It speaks X AIR OSC to the app and translates
/// through `Ui24Map`, so the mixer screens work unchanged. Because the Ui sends its whole state on connect and has no
/// "get", queries are answered from the state received so far. Callbacks arrive on a private background queue.
final class Ui24Transport: MixerTransport {
    var onMessage: ((OSCMessage) -> Void)?
    var onStateChange: ((NWConnection.State) -> Void)?

    private let queue = DispatchQueue(label: "hollymixer.ui24")
    private var connection: NWConnection?
    private var keepalive: DispatchSourceTimer?
    private var host = ""
    /// Every value received or sent, by Ui key.
    private var state: [String: UiValue] = [:]
    private var map = Ui24Map(model: .ui24)
    private var lastInbound = Date.distantPast
    /// An `/xinfo` waiting for the next line from the mixer, so its answer proves the mixer is still there.
    private var infoRequestedAt: Date?

    func connect(host: String) {
        queue.async { self.open(host: host) }
    }

    func disconnect() {
        queue.async { self.close() }
    }

    func send(_ message: OSCMessage) {
        queue.async { self.handleOutgoing(message) }
    }

    // MARK: - Connection

    private func open(host: String) {
        close()
        if host != self.host {
            state = [:]
            map = Ui24Map(model: .ui24)
        }
        self.host = host
        guard let url = URL(string: "ws://\(host)/") else { return }
        let connection = NWConnection(to: .url(url), using: Self.parameters())
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.connection === connection else { return }
            switch state {
            case .ready: self.startKeepalive()
            case .failed, .cancelled: self.stopKeepalive()
            default: break
            }
            self.onStateChange?(state)
        }
        self.connection = connection
        receive(on: connection)
        connection.start(queue: queue)
    }

    private func close() {
        stopKeepalive()
        connection?.cancel()
        connection = nil
        infoRequestedAt = nil
        lastInbound = .distantPast
    }

    static func parameters() -> NWParameters {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        return parameters
    }

    private func startKeepalive() {
        stopKeepalive()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.write(Ui24Protocol.keepalive) }
        timer.resume()
        keepalive = timer
    }

    private func stopKeepalive() {
        keepalive?.cancel()
        keepalive = nil
    }

    private func write(_ line: String) {
        guard let connection else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "ui24", metadata: [metadata])
        connection.send(content: Data((Ui24Protocol.framePrefix + line).utf8), contentContext: context,
                        isComplete: true, completion: .idempotent)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, self.connection === connection else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close || (data == nil && error == nil && metadata == nil) {
                // The mixer closed the socket (restart, too many clients): report it so the app reconnects.
                self.close()
                self.onStateChange?(.failed(.posix(.ECONNRESET)))
                return
            }
            if let data, let frame = String(data: data, encoding: .utf8) {
                self.handleFrame(frame)
            }
            if error == nil {
                self.receive(on: connection)
            }
        }
    }

    // MARK: - Incoming

    private func handleFrame(_ frame: String) {
        guard let lines = Ui24Protocol.lines(inFrame: frame) else { return }
        for line in lines {
            switch Ui24Protocol.parse(line) {
            case .number(let key, let value):
                received(key, .number(value))
            case .text(let key, let value):
                received(key, .text(value))
            case .meters(let bytes):
                if let blob = Ui24Map.xairMeters(fromVU: bytes) {
                    onMessage?(OSCMessage("/meters/1", .blob(blob)))
                }
            case .other:
                break
            }
        }
        lastInbound = Date()
        if infoRequestedAt != nil, !state.isEmpty {
            infoRequestedAt = nil
            sendInfo()
        }
    }

    private func received(_ key: String, _ value: UiValue) {
        state[key] = value
        if key == "model", case .text(let id) = value, id != map.model.id {
            map = Ui24Map(model: .named(id))
            pushAll()
            return
        }
        push(key)
    }

    /// Tells the app about every X AIR address that reads this Ui key.
    private func push(_ key: String) {
        guard let value = state[key] else { return }
        for address in map.addressesByKey[key] ?? [] {
            if let argument = map.bindings[address]?.oscValue(value) {
                onMessage?(OSCMessage(address, argument))
            }
        }
    }

    private func pushAll() {
        for key in state.keys { push(key) }
    }

    /// Answers `/xinfo` like an X AIR: ip, name, model, firmware.
    private func sendInfo() {
        let model = map.model.displayName
        var firmware = ""
        if case .text(let text)? = state["firmware"] { firmware = text }
        onMessage?(OSCMessage("/xinfo", .string(host), .string("Soundcraft \(model)"), .string(model),
                              .string(firmware)))
    }

    // MARK: - Outgoing

    private func handleOutgoing(_ message: OSCMessage) {
        switch message.address {
        case "/xinfo":
            guard connection != nil, !state.isEmpty else { return }
            // Answered with the next line from the mixer (meters arrive many times a second). If the mixer has gone
            // quiet but the socket still had traffic recently, answer anyway.
            if let since = infoRequestedAt, Date().timeIntervalSince(since) > 1,
               Date().timeIntervalSince(lastInbound) < 10 {
                infoRequestedAt = nil
                sendInfo()
            } else if infoRequestedAt == nil {
                infoRequestedAt = Date()
            }
            return
        case "/xremote", "/meters":
            return
        default:
            break
        }
        guard let argument = message.arguments.first else {
            answer(message.address)
            return
        }
        guard let binding = map.bindings[message.address],
              let value = binding.uiValue(argument, current: state[binding.key]) else { return }
        set(binding.key, value)
        let partner = Ui24Map.linkedKey(binding.key) { self.state[$0]?.numeric }
        if let partner {
            set(partner, value)
            push(partner)
        }
    }

    private func set(_ key: String, _ value: UiValue) {
        state[key] = value
        write(Ui24Protocol.setLine(key, value))
    }

    /// A query: answer from the state the mixer sent, like an X AIR would.
    private func answer(_ address: String) {
        if let value = Ui24Map.fixedValues[address] {
            onMessage?(OSCMessage(address, value))
            return
        }
        guard let binding = map.bindings[address], let value = state[binding.key],
              let argument = binding.oscValue(value) else { return }
        onMessage?(OSCMessage(address, argument))
    }
}

/// Connects to whatever mixer is at an address: tries X AIR (OSC over UDP) and Soundcraft Ui (WebSocket) at once and
/// keeps the one that answers. Every caller (saved address, typed address, musician pairing) works with either.
final class AutoTransport: MixerTransport {
    var onMessage: ((OSCMessage) -> Void)?
    var onStateChange: ((NWConnection.State) -> Void)?

    private let xair = MixerConnection()
    private let ui = Ui24Transport()
    private let lock = NSLock()
    private var host = ""
    private var isStopped = true
    private var isRetryScheduled = false
    /// The transport that answered at `host`, once known.
    private var active: MixerTransport?

    init() {
        xair.onMessage = { [weak self] message in self?.received(message, from: self?.xair) }
        ui.onMessage = { [weak self] message in self?.received(message, from: self?.ui) }
        xair.onStateChange = { [weak self] state in self?.changed(state, from: self?.xair) }
        ui.onStateChange = { [weak self] state in self?.changed(state, from: self?.ui) }
    }

    func connect(host: String) {
        let active: MixerTransport? = lock.withLock {
            if host != self.host { self.active = nil }
            self.host = host
            isStopped = false
            return self.active
        }
        if let active {
            active.connect(host: host)
        } else {
            xair.connect(host: host)
            ui.connect(host: host)
        }
    }

    func disconnect() {
        lock.withLock { isStopped = true }
        xair.disconnect()
        ui.disconnect()
    }

    func send(_ message: OSCMessage) {
        if let active = lock.withLock({ self.active }) {
            active.send(message)
        } else {
            xair.send(message)
            ui.send(message)
        }
    }

    private func received(_ message: OSCMessage, from source: MixerTransport?) {
        guard let source else { return }
        let deliver: Bool = lock.withLock {
            if active == nil, message.address == "/xinfo" {
                active = source
                if source === xair { ui.disconnect() } else { xair.disconnect() }
            }
            return active === source
        }
        if deliver { onMessage?(message) }
    }

    private func changed(_ state: NWConnection.State, from source: MixerTransport?) {
        guard let source else { return }
        let (active, host) = lock.withLock { (self.active, self.host) }
        if let active {
            if active === source { onStateChange?(state) }
            return
        }
        // Still looking: UDP reports the network problems; a refused WebSocket (`waiting` or `failed`) just means
        // "not a Ui", so try again a little later in case the mixer is still starting.
        var refused = false
        switch state {
        case .waiting, .failed: refused = true
        default: break
        }
        if source === xair {
            onStateChange?(state)
        } else if refused, lock.withLock({ () -> Bool in
            guard !isRetryScheduled else { return false }
            isRetryScheduled = true
            return true
        }) {
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                let retry = self.lock.withLock {
                    self.isRetryScheduled = false
                    return !self.isStopped && self.active == nil && self.host == host
                }
                if retry { self.ui.connect(host: host) }
            }
        }
    }
}
