import Foundation
import Network

/// Carries OSC messages to and from a mixer: the real one over UDP, or the in-app demo.
protocol MixerTransport: AnyObject {
    var onMessage: ((OSCMessage) -> Void)? { get set }
    var onStateChange: ((NWConnection.State) -> Void)? { get set }
    func connect(host: String)
    func disconnect()
    func send(_ message: OSCMessage)
}

/// UDP transport to an X AIR mixer. Callbacks arrive on a private background queue.
final class MixerConnection: MixerTransport {
    static let port: UInt16 = 10024

    var onMessage: ((OSCMessage) -> Void)?
    var onStateChange: ((NWConnection.State) -> Void)?

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "hollymixer.osc")

    func connect(host: String) {
        disconnect()
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: Self.port)!,
            using: .udp
        )
        connection.stateUpdateHandler = { [weak self] state in
            self?.onStateChange?(state)
        }
        self.connection = connection
        receive(on: connection)
        connection.start(queue: queue)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
    }

    func send(_ message: OSCMessage) {
        connection?.send(content: message.encoded(), completion: .idempotent)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if let data, let message = OSCMessage(data: data) {
                self?.onMessage?(message)
            }
            if error == nil, self?.connection === connection {
                self?.receive(on: connection)
            }
        }
    }
}
