import Darwin
import Foundation
import Network
import Observation

/// A mixer that answered `/xinfo`.
struct DiscoveredMixer: Identifiable, Hashable {
    let ip: String
    let name: String
    let model: String
    let firmware: String
    /// Round trip in milliseconds.
    let latency: Int

    var id: String { ip }
}

/// Result of "Check my network".
struct NetworkCheck {
    let host: String
    let replies: Int
    let attempts: Int
    /// Median round trip in milliseconds, nil if nothing answered.
    let latency: Int?

    var isReachable: Bool { replies > 0 }
    var lossPercent: Double { Double(attempts - replies) / Double(attempts) * 100 }
}

/// Finds X AIR mixers by sending `/xinfo` to every address on the device's local /24 networks, and Soundcraft Ui
/// mixers by opening their WebSocket on every address with port 80 open (plus 10.10.1.1, the Ui's own Wi-Fi).
/// Unicast probes don't need Apple's multicast entitlement, unlike a broadcast.
enum MixerDiscovery {
    /// Where a Soundcraft Ui is on its own Wi-Fi hotspot ("Soundcraft Ui24-…").
    static let soundcraftHotspotHost = "10.10.1.1"

    static func scan(alsoTry extraHosts: [String] = [], timeout: TimeInterval = 1.5) async -> [DiscoveredMixer] {
        let subnetHosts = localSubnets().flatMap { subnet in (1...254).map { "\(subnet).\($0)" } }
        let hosts = Array(Set(extraHosts + subnetHosts))
        async let xair = Task.detached(priority: .userInitiated) { probe(hosts: hosts, timeout: timeout) }.value
        async let soundcraft = scanSoundcraft(hosts: hosts, alsoTry: extraHosts + [soundcraftHotspotHost],
                                              timeout: timeout)
        let found = await xair
        let known = Set(found.map(\.ip))
        return (found + (await soundcraft).filter { !known.contains($0.ip) })
            .sorted { $0.ip.compare($1.ip, options: .numeric) == .orderedAscending }
    }

    /// Soundcraft Ui mixers among `hosts` (those with a web server) and `extraHosts` (always tried).
    private static func scanSoundcraft(hosts: [String], alsoTry extraHosts: [String],
                                       timeout: TimeInterval) async -> [DiscoveredMixer] {
        let webHosts = await Task.detached(priority: .userInitiated) {
            openPort(Ui24Protocol.port, on: hosts, timeout: min(timeout, 1))
        }.value
        let candidates = Array(Set(webHosts + extraHosts.filter { !$0.isEmpty }))
        return await withTaskGroup(of: DiscoveredMixer?.self) { group in
            for host in candidates {
                group.addTask { await Ui24Probe.probe(host: host, timeout: timeout) }
            }
            var found: [DiscoveredMixer] = []
            for await mixer in group {
                if let mixer { found.append(mixer) }
            }
            return found
        }
    }

    /// Pings one mixer with `/xinfo` `count` times; a Soundcraft Ui (no `/xinfo`) is checked by opening its WebSocket
    /// a few times instead.
    static func check(host: String, count: Int = 20) async -> NetworkCheck {
        let answersXinfo = await Task.detached(priority: .userInitiated) {
            !probe(hosts: [host], timeout: 0.5).isEmpty
        }.value
        if !answersXinfo, await Ui24Probe.probe(host: host, timeout: 1.5) != nil {
            let attempts = max(1, count / 4)
            var times: [Int] = []
            for _ in 0..<attempts {
                if let mixer = await Ui24Probe.probe(host: host, timeout: 1) {
                    times.append(mixer.latency)
                }
            }
            let sorted = times.sorted()
            return NetworkCheck(host: host, replies: times.count, attempts: attempts,
                                latency: sorted.isEmpty ? nil : sorted[sorted.count / 2])
        }
        return await Task.detached(priority: .userInitiated) {
            var times: [Int] = []
            for _ in 0..<count {
                if let mixer = probe(hosts: [host], timeout: 0.3).first {
                    times.append(mixer.latency)
                }
            }
            let sorted = times.sorted()
            return NetworkCheck(host: host, replies: times.count, attempts: count,
                                latency: sorted.isEmpty ? nil : sorted[sorted.count / 2])
        }.value
    }

    /// "192.168.1" for each active Wi-Fi/Ethernet IPv4 interface.
    static func localSubnets() -> [String] {
        var subnets: [String] = []
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return [] }
        defer { freeifaddrs(addresses) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            let flags = Int32(interface.ifa_flags)
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  String(cString: interface.ifa_name).hasPrefix("en") else { continue }
            let capacity = Int(NI_MAXHOST)
            var host = [CChar](repeating: 0, count: capacity)
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(capacity),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let octets = String(cString: host).split(separator: ".")
            if octets.count == 4 {
                subnets.append(octets.prefix(3).joined(separator: "."))
            }
        }
        return Array(Set(subnets))
    }

    /// The hosts that accept a TCP connection on `port`, tried 128 at a time with non-blocking connects.
    private static func openPort(_ port: UInt16, on hosts: [String], timeout: TimeInterval) -> [String] {
        var open: [String] = []
        for start in stride(from: 0, to: hosts.count, by: 128) {
            var sockets: [(handle: Int32, host: String)] = []
            for host in hosts[start..<min(start + 128, hosts.count)] {
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = in_port_t(port).bigEndian
                guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { continue }
                let handle = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
                guard handle >= 0 else { continue }
                var on: Int32 = 1
                setsockopt(handle, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                _ = fcntl(handle, F_SETFL, fcntl(handle, F_GETFL, 0) | O_NONBLOCK)
                let result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if result == 0 || errno == EINPROGRESS {
                    sockets.append((handle, host))
                } else {
                    close(handle)
                }
            }
            var polls = sockets.map { pollfd(fd: $0.handle, events: Int16(POLLOUT), revents: 0) }
            var pending = polls.count
            let deadline = Date().addingTimeInterval(timeout)
            while pending > 0 {
                let wait = Int32(deadline.timeIntervalSinceNow * 1000)
                guard wait > 0, poll(&polls, nfds_t(polls.count), wait) > 0 else { break }
                for index in polls.indices where polls[index].fd >= 0 && polls[index].revents != 0 {
                    var error: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(sockets[index].handle, SOL_SOCKET, SO_ERROR, &error, &length)
                    if error == 0 { open.append(sockets[index].host) }
                    polls[index].fd = -1
                    pending -= 1
                }
            }
            sockets.forEach { close($0.handle) }
        }
        return open
    }

    /// Sends `/xinfo` to each host and collects the replies until `timeout`.
    private static func probe(hosts: [String], timeout: TimeInterval) -> [DiscoveredMixer] {
        let socketHandle = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketHandle >= 0 else { return [] }
        defer { close(socketHandle) }
        var receiveTimeout = timeval(tv_sec: 0, tv_usec: 50_000)
        setsockopt(socketHandle, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

        let packet = [UInt8](OSCMessage("/xinfo").encoded())
        let start = Date()
        for host in hosts {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(MixerConnection.port).bigEndian
            guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { continue }
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socketHandle, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var found: [String: DiscoveredMixer] = [:]
        let capacity = 2048
        var buffer = [UInt8](repeating: 0, count: capacity)
        let deadline = start.addingTimeInterval(timeout)
        while Date() < deadline {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(socketHandle, &buffer, capacity, 0, $0, &length)
                }
            }
            guard count > 0,
                  let message = OSCMessage(data: Data(buffer[0..<count])),
                  message.address == "/xinfo" else { continue }
            let latency = max(1, Int(Date().timeIntervalSince(start) * 1000))
            let strings = message.arguments.compactMap { argument -> String? in
                if case .string(let value) = argument { return value }
                return nil
            }
            let ipCapacity = Int(INET_ADDRSTRLEN)
            var ipText = [CChar](repeating: 0, count: ipCapacity)
            inet_ntop(AF_INET, &from.sin_addr, &ipText, socklen_t(ipCapacity))
            let ip = String(cString: ipText)
            guard strings.count >= 4, found[ip] == nil else { continue }
            found[ip] = DiscoveredMixer(ip: ip, name: strings[1], model: strings[2],
                                        firmware: strings[3], latency: latency)
            if hosts.count == 1 { break }
        }
        return found.values.sorted { $0.ip.compare($1.ip, options: .numeric) == .orderedAscending }
    }
}

/// A mixer connected to before, remembered on this device.
struct RecentMixer: Codable, Identifiable, Hashable {
    let ip: String
    let name: String
    let lastUsed: Date

    var id: String { ip }

    static func load(from json: String) -> [RecentMixer] {
        (try? JSONDecoder().decode([RecentMixer].self, from: Data(json.utf8))) ?? []
    }

    static func save(_ mixers: [RecentMixer]) -> String {
        (try? String(decoding: JSONEncoder().encode(mixers), as: UTF8.self)) ?? "[]"
    }
}

extension DiscoveredMixer {
    /// Newest XR18 firmware the design was made against.
    static let latestFirmware = "1.16"

    /// A Soundcraft Ui (Ui24R, Ui16, Ui12) rather than an X AIR.
    var isSoundcraft: Bool { model.hasPrefix("Ui") }

    /// True when an X AIR runs older firmware than `latestFirmware` ("1.15" < "1.16").
    var isFirmwareOutdated: Bool {
        guard !isSoundcraft else { return false }
        func parts(_ text: String) -> [Int] { text.split(separator: ".").map { Int($0) ?? 0 } }
        let mine = parts(firmware), latest = parts(Self.latestFirmware)
        for index in 0..<max(mine.count, latest.count) {
            let a = index < mine.count ? mine[index] : 0
            let b = index < latest.count ? latest[index] : 0
            if a != b { return a < b }
        }
        return false
    }
}

/// What kind of network this device is on right now (Wi-Fi, Ethernet, mobile data or none).
@MainActor
@Observable
final class NetworkPathInfo {
    enum Kind { case wifi, ethernet, cellular, other, none }

    private(set) var kind = Kind.other
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let kind: Kind
            if path.status != .satisfied { kind = .none }
            else if path.usesInterfaceType(.wifi) { kind = .wifi }
            else if path.usesInterfaceType(.wiredEthernet) { kind = .ethernet }
            else if path.usesInterfaceType(.cellular) { kind = .cellular }
            else { kind = .other }
            Task { @MainActor in self?.kind = kind }
        }
        monitor.start(queue: DispatchQueue(label: "hollymixer.path"))
    }

    deinit { monitor.cancel() }

    var title: String {
        switch kind {
        case .wifi: return L("Wi-Fi")
        case .ethernet: return L("Ethernet")
        case .cellular: return L("Mobile data only")
        case .other: return L("Network")
        case .none: return L("Offline")
        }
    }

    var hint: String {
        switch kind {
        case .wifi: return L("Connected to Wi-Fi. Use the same network as the mixer.")
        case .ethernet: return L("Connected over a wired adapter.")
        case .cellular: return L("Not on Wi-Fi: the mixer can't be reached over mobile data.")
        case .other: return L("Connected.")
        case .none: return L("No network. Join the mixer's Wi-Fi or plug in Ethernet.")
        }
    }

    var isGood: Bool { kind == .wifi || kind == .ethernet || kind == .other }
}

/// Checks whether a Soundcraft Ui mixer is at an address: opens its WebSocket and waits for the state it sends.
final class Ui24Probe {
    private let host: String
    private let queue = DispatchQueue(label: "hollymixer.ui24probe")
    private let start = Date()
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<DiscoveredMixer?, Never>?
    private var firstReply: Date?
    private var model: String?
    private var firmware: String?

    private init(host: String) {
        self.host = host
    }

    /// The mixer at `host`, or nil if nothing there speaks the Ui protocol within `timeout`.
    static func probe(host: String, timeout: TimeInterval) async -> DiscoveredMixer? {
        guard let url = URL(string: "ws://\(host)/") else { return nil }
        let probe = Ui24Probe(host: host)
        return await withCheckedContinuation { continuation in
            probe.queue.async {
                probe.continuation = continuation
                let connection = NWConnection(to: .url(url), using: Ui24Transport.parameters())
                probe.connection = connection
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .waiting, .failed: probe.finish()
                    default: break
                    }
                }
                probe.receive()
                connection.start(queue: probe.queue)
                probe.queue.asyncAfter(deadline: .now() + timeout) { probe.finish() }
            }
        }
    }

    private func receive() {
        connection?.receiveMessage { [self] data, _, _, error in
            if let data, let frame = String(data: data, encoding: .utf8), let lines = Ui24Protocol.lines(inFrame: frame) {
                for line in lines {
                    let parsed = Ui24Protocol.parse(line)
                    switch parsed {
                    case .text(let key, let value) where key == "model": model = value
                    case .text(let key, let value) where key == "firmware": firmware = value
                    default: break
                    }
                    if firstReply == nil, parsed != .other {
                        firstReply = Date()
                        // The model and firmware usually come in the first frames; don't wait the full timeout.
                        queue.asyncAfter(deadline: .now() + 0.4) { self.finish() }
                    }
                }
            }
            if model != nil, firmware != nil {
                finish()
            } else if error == nil, data != nil {
                receive()
            }
        }
    }

    /// Reports what was seen (once) and closes the socket.
    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        connection?.cancel()
        connection = nil
        guard let firstReply else {
            continuation.resume(returning: nil)
            return
        }
        let name = Ui24Protocol.Model.named(model).displayName
        continuation.resume(returning: DiscoveredMixer(
            ip: host, name: "Soundcraft \(name)", model: name, firmware: firmware ?? "",
            latency: max(1, Int(firstReply.timeIntervalSince(start) * 1000))))
    }
}
