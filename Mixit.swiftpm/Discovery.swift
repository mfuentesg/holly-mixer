import Darwin
import Foundation

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

/// Finds X AIR mixers by sending `/xinfo` to every address on the device's local /24 networks.
/// Unicast probes don't need Apple's multicast entitlement, unlike a broadcast.
enum MixerDiscovery {
    static func scan(alsoTry extraHosts: [String] = [], timeout: TimeInterval = 1.5) async -> [DiscoveredMixer] {
        await Task.detached(priority: .userInitiated) {
            let subnetHosts = localSubnets().flatMap { subnet in (1...254).map { "\(subnet).\($0)" } }
            let hosts = Array(Set(extraHosts + subnetHosts))
            return probe(hosts: hosts, timeout: timeout)
        }.value
    }

    /// Pings one mixer with `/xinfo` `count` times.
    static func check(host: String, count: Int = 20) async -> NetworkCheck {
        await Task.detached(priority: .userInitiated) {
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
