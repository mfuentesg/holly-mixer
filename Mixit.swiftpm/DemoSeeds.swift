import Foundation

/// Extra starting values for the demo mixer, added on top of DemoTransport's own state.
enum DemoSeeds {
    /// Preamp, gate, EQ and dynamics values for channels, buses and main.
    static func channelDetail() -> [String: OSCArgument] {
        [:]
    }
}
