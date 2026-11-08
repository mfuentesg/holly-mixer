import Foundation
import Observation
import Security

/// One saved recording of a source's RTA, with the level statistics of the strip. The JSON is the same shape the
/// Python tool `tools/xr18_eq_record.py` writes (snake_case keys), so recordings can be analysed with either.
struct EQRecording: Codable, Identifiable, Equatable {
    struct Frames: Codable, Equatable {
        var rta: Int
        var rtaActive: Int
        var levels: Int
    }

    struct Level: Codable, Equatable {
        var peakDb: Float
        var meanActiveDb: Float?
        var activePct: Float
    }

    struct Axis: Codable, Equatable {
        var type = "log"
        var minHz = 20.0
        var maxHz = 20000.0
        /// The log axis is an assumption until it has been checked with a known tone on the real mixer.
        var verified = false
    }

    struct Meta: Codable, Equatable {
        var label: String
        var taken: String
        var seconds: Double
        var note: String
        var rtaAxis: Axis
        var rtaGateDb: Float
        var levelGateDb: Float
    }

    var frames: Frames
    var rta: EQSpectrum
    var levels: [String: Level]
    var meta: Meta

    var id: String { meta.taken + meta.label }

    /// Enough signal to say something about the spectrum.
    var hasSignal: Bool { frames.rtaActive >= 20 }

    var date: Date? { ISO8601DateFormatter().date(from: meta.taken) }

    /// The key used in file names and in the Python tools: ch01, bus3, main, aux, rtn2.
    @MainActor
    static func label(for strip: Strip) -> String {
        switch strip.kind {
        case .channel(let number): return String(format: "ch%02d", number)
        case .auxIn: return "aux"
        case .fxReturn(let number): return "rtn\(number)"
        case .bus(let number): return "bus\(number)"
        case .fxSend(let number): return "fx\(number)"
        case .main: return "main"
        }
    }
}

/// Recordings live in Documents/EQSessions/, one JSON file each.
enum EQRecordingStore {
    private static var folder: URL? {
        try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("EQSessions", isDirectory: true)
    }

    @discardableResult
    static func save(_ recording: EQRecording) -> Bool {
        guard let folder else { return false }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stamp = recording.meta.taken.replacingOccurrences(of: ":", with: "")
            let url = folder.appendingPathComponent("session-\(recording.meta.label)-\(stamp).json")
            try encoder.encode(recording).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The newest recording of a source (by label), or nil.
    static func latest(label: String) -> EQRecording? {
        guard let folder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return files
            .filter { $0.lastPathComponent.hasPrefix("session-\(label)-") && $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(EQRecording.self, from: Data(contentsOf: $0)) }
            .max { $0.meta.taken < $1.meta.taken }
    }
}

/// Records the RTA while the EQ assistant's sheet is open and the user asks for it.
@MainActor
@Observable
final class EQSpectrumRecorder {
    enum State: Equatable { case idle, recording, finished }

    static let rtaGate: Float = -75
    static let levelGate: Float = -55

    private(set) var state = State.idle
    private(set) var elapsed = 0.0
    private(set) var activeFrames = 0
    private(set) var totalFrames = 0
    /// The latest RTA frame, for the live plot.
    private(set) var live: [Float] = []
    private(set) var result: EQRecording?
    var duration = 30.0

    @ObservationIgnored private var power = [Double](repeating: 0, count: EQSpectrum.binCount)
    @ObservationIgnored private var peak = [Float](repeating: -128, count: EQSpectrum.binCount)
    @ObservationIgnored private var started = Date()
    @ObservationIgnored private var levelPeak: Float = -128
    @ObservationIgnored private var levelPower = 0.0
    @ObservationIgnored private var levelActive = 0
    @ObservationIgnored private var levelFrames = 0
    @ObservationIgnored private weak var mixer: Mixer?
    @ObservationIgnored private var strip: Strip?

    func start(mixer: Mixer, strip: Strip) {
        power = [Double](repeating: 0, count: EQSpectrum.binCount)
        peak = [Float](repeating: -128, count: EQSpectrum.binCount)
        levelPeak = -128
        levelPower = 0
        levelActive = 0
        levelFrames = 0
        activeFrames = 0
        totalFrames = 0
        elapsed = 0
        live = []
        result = nil
        self.mixer = mixer
        self.strip = strip
        started = Date()
        state = .recording
        mixer.setRTAListener { [weak self] bins in self?.receive(bins) }
    }

    /// Stops and discards a recording in progress (the sheet was closed).
    func cancel() {
        guard state == .recording else { return }
        mixer?.setRTAListener(nil)
        state = .idle
    }

    /// Stops and keeps what was recorded so far.
    func stop() {
        guard state == .recording else { return }
        finish()
    }

    private func receive(_ bins: [Float]) {
        guard state == .recording, bins.count >= EQSpectrum.binCount else { return }
        totalFrames += 1
        live = Array(bins.prefix(EQSpectrum.binCount))
        elapsed = Date().timeIntervalSince(started)
        if let strip {
            let level = strip.meter
            levelFrames += 1
            levelPeak = max(levelPeak, level)
            if level >= Self.levelGate {
                levelActive += 1
                levelPower += pow(10, Double(level) / 10)
            }
        }
        if (live.max() ?? -128) >= Self.rtaGate {
            activeFrames += 1
            for (index, value) in live.enumerated() {
                power[index] += pow(10, Double(value) / 10)
                peak[index] = max(peak[index], value)
            }
        }
        if elapsed >= duration { finish() }
    }

    private func finish() {
        mixer?.setRTAListener(nil)
        let count = Double(max(activeFrames, 1))
        let mean = power.map { Float((10 * log10(max($0 / count, 1e-13)) * 100).rounded() / 100) }
        let label = strip.map(EQRecording.label(for:)) ?? "unknown"
        var levels: [String: EQRecording.Level] = [:]
        if strip != nil {
            levels[label] = EQRecording.Level(
                peakDb: levelPeak,
                meanActiveDb: levelActive > 0 ? Float(10 * log10(levelPower / Double(levelActive))) : nil,
                activePct: levelFrames > 0 ? Float(100 * Double(levelActive) / Double(levelFrames)) : 0)
        }
        let recording = EQRecording(
            frames: .init(rta: totalFrames, rtaActive: activeFrames, levels: levelFrames),
            rta: EQSpectrum(meanDb: mean, peakDb: peak),
            levels: levels,
            meta: .init(label: label, taken: ISO8601DateFormatter().string(from: Date()),
                        seconds: (elapsed * 10).rounded() / 10, note: "", rtaAxis: .init(),
                        rtaGateDb: Self.rtaGate, levelGateDb: Self.levelGate))
        EQRecordingStore.save(recording)
        result = recording
        state = .finished
    }
}

/// The user's Claude API key, in the Keychain (never in the app's preferences, a backup or the repository).
enum APIKeyStore {
    /// Mirror of "a key is stored" in the preferences (the key itself never goes there), so views can react to it.
    static let configuredKey = "aiKeyConfigured"
    private static let service = "com.mfuentesg.hollymixer.anthropic"
    private static let account = "api-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Re-reads the Keychain into the preferences mirror (a key saved by an earlier version has no mirror yet).
    static func syncConfigured() {
        UserDefaults.standard.set(!(load() ?? "").isEmpty, forKey: configuredKey)
    }

    static func load() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// An empty key removes the stored one.
    static func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.set(!trimmed.isEmpty, forKey: configuredKey)
        guard !trimmed.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
