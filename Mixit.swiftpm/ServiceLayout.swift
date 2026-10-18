import CryptoKit
import Foundation
import Observation
import SwiftUI

/// One fader in the volunteer layout.
struct ServiceItem: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Name shown to volunteers, e.g. "Pastor".
    var label: String
    /// OSC base of the target strip ("/ch/01", "/rtn/aux", "/bus/3", "/lr"); `Strip.Kind` is not Codable.
    var base: String
    /// Index into `Theme.channelColors`; nil uses the strip's own colour.
    var colorIndex: Int?
    /// Lowest and highest level the fader may reach, in dB.
    var minDB: Float
    var maxDB: Float
    var allowMute: Bool

    /// Fader positions (0...1) of the limits.
    var lowerFader: Float { decibelsToFader(minDB) }
    var upperFader: Float { decibelsToFader(maxDB) }

    func clamped(_ value: Float) -> Float {
        min(max(value, lowerFader), upperFader)
    }

    /// The strip this item controls, if the mixer still has it.
    @MainActor
    func strip(in mixer: Mixer) -> Strip? {
        (mixer.inputs + mixer.buses + mixer.fxSends + [mixer.main]).first { $0.base == base }
    }

    @MainActor
    func color(for strip: Strip) -> Color {
        colorIndex.map { Theme.channelColors[$0 % 8] } ?? strip.color
    }
}

/// The title and ordered faders of a Service Mode layout.
struct ServiceLayout: Codable, Equatable {
    var title = "Domingo AM · Volunteer"
    var items: [ServiceItem] = []
}

/// Formats a dB limit with a true minus sign: "+8.0", "−20.0", "0.0".
func serviceFormatDB(_ db: Float) -> String {
    let text = String(format: "%.1f", abs(db))
    if text == "0.0" { return "0.0" }
    return (db > 0 ? "+" : "−") + text
}

/// Holds the Service Mode layout and PIN, persisted as JSON in Documents. The PIN is stored salted and hashed.
@MainActor
@Observable
final class ServiceLayoutStore {
    static let shared = ServiceLayoutStore()

    nonisolated static let pinLength = 4
    nonisolated static let defaultPIN = "0000"
    nonisolated static let maxAttempts = 3
    nonisolated static let lockoutSeconds: TimeInterval = 30

    private struct Persisted: Codable {
        var layout: ServiceLayout
        var isSeeded: Bool
        var pinSalt: String?
        var pinHash: String?
    }

    private(set) var layout = ServiceLayout()
    private(set) var isSeeded = false
    private var pinSalt: String?
    private var pinHash: String?
    private(set) var failedAttempts = 0
    private(set) var lockedUntil: Date?

    @ObservationIgnored private let url: URL

    init(url: URL? = nil) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.url = url ?? documents.appendingPathComponent("ServiceLayout.json")
        if let data = try? Data(contentsOf: self.url),
           let saved = try? JSONDecoder().decode(Persisted.self, from: data) {
            layout = saved.layout
            isSeeded = saved.isSeeded
            pinSalt = saved.pinSalt
            pinHash = saved.pinHash
        }
    }

    /// True once the sound lead has set their own PIN.
    var hasCustomPIN: Bool { pinHash != nil }

    func replace(_ newLayout: ServiceLayout) {
        guard newLayout != layout else { return }
        layout = newLayout
        save()
    }

    /// Builds the default layout from the live mixer the first time it is needed.
    func seedIfNeeded(_ mixer: Mixer) {
        guard !isSeeded else { return }
        layout = Self.defaultLayout(for: mixer)
        isSeeded = true
        save()
    }

    /// Pulpito as "Pastor", Mic Martin as "Worship Lead", Aux In as "Playback" and Main LR as "Main".
    static func defaultLayout(for mixer: Mixer) -> ServiceLayout {
        func channel(named name: String, fallback: Int) -> Strip? {
            mixer.channels.first { $0.name.lowercased().contains(name) }
                ?? mixer.channels.first { $0.kind == .channel(fallback) }
        }
        let candidates: [(label: String, strip: Strip?, min: Float, max: Float, mute: Bool)] = [
            ("Pastor", channel(named: "pulpito", fallback: 1), -20, 8, true),
            ("Worship Lead", channel(named: "martin", fallback: 5), -10, 8, true),
            ("Playback", mixer.auxIn, -40, 0, true),
            ("Main", mixer.main, -10, 0, false),
        ]
        var items: [ServiceItem] = []
        for candidate in candidates {
            guard let strip = candidate.strip else { continue }
            items.append(ServiceItem(label: candidate.label, base: strip.base, colorIndex: nil,
                                     minDB: candidate.min, maxDB: candidate.max, allowMute: candidate.mute))
        }
        if items.isEmpty, let first = (mixer.inputs + [mixer.main]).first {
            items.append(ServiceItem(label: first.displayName, base: first.base, colorIndex: nil,
                                     minDB: -20, maxDB: 0, allowMute: false))
        }
        return ServiceLayout(items: items)
    }

    // MARK: - PIN

    func verifyPIN(_ pin: String) -> Bool {
        guard let pinHash, let pinSalt else { return pin == Self.defaultPIN }
        return Self.hash(pin, salt: pinSalt) == pinHash
    }

    func setPIN(_ pin: String) {
        let salt = UUID().uuidString
        pinSalt = salt
        pinHash = Self.hash(pin, salt: salt)
        save()
    }

    private static func hash(_ pin: String, salt: String) -> String {
        SHA256.hash(data: Data((salt + ":" + pin).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func isLockedOut(at date: Date = Date()) -> Bool {
        if let lockedUntil, lockedUntil > date { return true }
        return false
    }

    /// Counts a wrong PIN; the third in a row locks entry for 30 seconds.
    func registerFailure() {
        failedAttempts += 1
        if failedAttempts >= Self.maxAttempts {
            failedAttempts = 0
            lockedUntil = Date().addingTimeInterval(Self.lockoutSeconds)
        }
    }

    func resetAttempts() {
        failedAttempts = 0
        lockedUntil = nil
    }

    private func save() {
        let saved = Persisted(layout: layout, isSeeded: isSeeded, pinSalt: pinSalt, pinHash: pinHash)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
