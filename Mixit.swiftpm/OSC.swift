import Foundation

/// A single OSC argument. X AIR mixers only use these four types.
enum OSCArgument: Equatable {
    case int(Int32)
    case float(Float)
    case string(String)
    case blob([UInt8])
}

/// One OSC message: an address plus typed arguments.
struct OSCMessage: Equatable {
    var address: String
    var arguments: [OSCArgument]

    init(_ address: String, _ arguments: OSCArgument...) {
        self.address = address
        self.arguments = arguments
    }

    func encoded() -> Data {
        var data = Data()
        data.appendOSCString(address)
        var tags = ","
        for argument in arguments {
            switch argument {
            case .int: tags += "i"
            case .float: tags += "f"
            case .string: tags += "s"
            case .blob: tags += "b"
            }
        }
        data.appendOSCString(tags)
        for argument in arguments {
            switch argument {
            case .int(let value):
                data.appendUInt32(UInt32(bitPattern: value))
            case .float(let value):
                data.appendUInt32(value.bitPattern)
            case .string(let value):
                data.appendOSCString(value)
            case .blob(let bytes):
                data.appendUInt32(UInt32(bytes.count))
                data.append(contentsOf: bytes)
                data.append(contentsOf: [UInt8](repeating: 0, count: (4 - bytes.count % 4) % 4))
            }
        }
        return data
    }

    init?(data: Data) {
        var reader = OSCReader(bytes: [UInt8](data))
        guard let address = reader.readString() else { return nil }
        self.address = address
        self.arguments = []
        guard reader.hasMore else { return }
        guard let tags = reader.readString(), tags.first == "," else { return nil }
        for tag in tags.dropFirst() {
            switch tag {
            case "i":
                guard let value = reader.readUInt32() else { return nil }
                arguments.append(.int(Int32(bitPattern: value)))
            case "f":
                guard let value = reader.readUInt32() else { return nil }
                arguments.append(.float(Float(bitPattern: value)))
            case "s":
                guard let value = reader.readString() else { return nil }
                arguments.append(.string(value))
            case "b":
                guard let size = reader.readUInt32(), let bytes = reader.readBytes(Int(size)) else { return nil }
                arguments.append(.blob(bytes))
            default:
                return nil
            }
        }
    }
}

private struct OSCReader {
    let bytes: [UInt8]
    var offset = 0

    var hasMore: Bool { offset < bytes.count }

    /// Reads a null-terminated string padded to a multiple of 4 bytes.
    mutating func readString() -> String? {
        guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0) else { return nil }
        let value = String(decoding: bytes[offset..<end], as: UTF8.self)
        offset = (end + 4) & ~3
        return value
    }

    mutating func readUInt32() -> UInt32? {
        guard offset + 4 <= bytes.count else { return nil }
        let value = bytes[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        offset += 4
        return value
    }

    mutating func readBytes(_ count: Int) -> [UInt8]? {
        guard count >= 0, offset + count <= bytes.count else { return nil }
        let value = Array(bytes[offset..<offset + count])
        offset += (count + 3) & ~3
        return value
    }
}

private extension Data {
    mutating func appendOSCString(_ string: String) {
        let utf8 = Array(string.utf8)
        append(contentsOf: utf8)
        append(contentsOf: [UInt8](repeating: 0, count: 4 - utf8.count % 4))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(contentsOf: [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ])
    }
}
