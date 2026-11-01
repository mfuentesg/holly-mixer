import AVFoundation
import Foundation
import Observation

// Measures the room with the device's microphone: the spectrum of pink noise played through the PA (what the
// audience hears, once PA and room have had their say) and the reverberation time from a hand clap. Only the
// numbers are kept; no audio is saved or sent anywhere.

/// What the last measurements of the room found. The spectrum is relative to the 500 Hz-2 kHz level and uses the
/// same 100 log-spaced bins (20 Hz-20 kHz) as the mixer's RTA, so `EQSpectrum` can summarise it.
struct RoomMeasurement: Codable, Equatable {
    var taken: String
    var sampleRate: Double
    /// Pink noise through the PA, dB relative to the mids. A flat line is a flat room. nil until measured.
    var bins: [Float]?
    /// Broadband reverberation time in seconds, from a clap. nil until measured.
    var rt60: Float?

    var date: Date? { ISO8601DateFormatter().date(from: taken) }
}

/// The room measurements, in Documents/EQSessions/room.json (the newest spectrum and the newest reverb time).
enum RoomStore {
    private static var url: URL? {
        try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("EQSessions", isDirectory: true).appendingPathComponent("room.json")
    }

    static func latest() -> RoomMeasurement? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(RoomMeasurement.self, from: data)
    }

    /// Keeps what the earlier measurement had and replaces the part that was just measured.
    @discardableResult
    static func merge(bins: [Float]? = nil, rt60: Float? = nil, sampleRate: Double) -> RoomMeasurement? {
        var current = latest() ?? RoomMeasurement(taken: "", sampleRate: sampleRate, bins: nil, rt60: nil)
        if let bins { current.bins = bins }
        if let rt60 { current.rt60 = rt60 }
        current.sampleRate = sampleRate
        current.taken = ISO8601DateFormatter().string(from: Date())
        guard let url else { return current }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(current).write(to: url, options: .atomic)
        } catch {
            return current
        }
        return current
    }
}

/// Turns microphone samples into a 100-bin spectrum (Goertzel on Hann-windowed blocks) or a level envelope. All the
/// work happens on its own serial queue, never on the audio thread.
final class RoomAnalyzer: @unchecked Sendable {
    enum Mode { case spectrum, reverb }

    private let queue = DispatchQueue(label: "holly.room-analyzer")
    private let mode: Mode
    let sampleRate: Double

    private let block = 16384
    private lazy var window: [Double] = (0..<block).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(block - 1)) }
    private lazy var coefficients: [Double] = (0..<EQSpectrum.binCount).map {
        2 * cos(2 * Double.pi * EQSpectrum.frequency(ofBin: $0) / sampleRate)
    }

    // Touched only on `queue`.
    private var pending: [Float] = []
    private var power = [Double](repeating: 0, count: EQSpectrum.binCount)
    private var blocks = 0
    private var envelope: [Float] = []
    private var hopAccumulator = 0.0
    private var hopCount = 0
    private var level: Float = -90

    init(mode: Mode, sampleRate: Double) {
        self.mode = mode
        self.sampleRate = sampleRate
    }

    /// Called from the audio thread: only copies, then hands over.
    func feed(_ samples: [Float]) {
        queue.async { self.consume(samples) }
    }

    private func consume(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let meanSquare = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        level = Float(10 * log10(max(meanSquare, 1e-12)))
        switch mode {
        case .reverb:
            let hop = max(Int(sampleRate / 100), 1)
            for sample in samples {
                hopAccumulator += Double(sample) * Double(sample)
                hopCount += 1
                if hopCount == hop {
                    envelope.append(Float(10 * log10(max(hopAccumulator / Double(hop), 1e-12))))
                    hopAccumulator = 0
                    hopCount = 0
                }
            }
        case .spectrum:
            pending.append(contentsOf: samples)
            while pending.count >= block {
                accumulate(Array(pending.prefix(block)))
                pending.removeFirst(block)
            }
        }
    }

    private func accumulate(_ samples: [Float]) {
        var windowed = [Double](repeating: 0, count: block)
        for index in 0..<block { windowed[index] = Double(samples[index]) * window[index] }
        windowed.withUnsafeBufferPointer { x in
            for (bin, coefficient) in coefficients.enumerated() {
                var s1 = 0.0
                var s2 = 0.0
                for sample in x {
                    let s0 = sample + coefficient * s1 - s2
                    s2 = s1
                    s1 = s0
                }
                power[bin] += s1 * s1 + s2 * s2 - coefficient * s1 * s2
            }
        }
        blocks += 1
    }

    /// The spectrum so far in dB relative to the 500 Hz-2 kHz level, or nil before the first block is done.
    func spectrum() -> [Float]? {
        queue.sync { Self.relativeBins(power: power, blocks: blocks) }
    }

    func currentLevel() -> Float {
        queue.sync { level }
    }

    func reverbTime() -> Float? {
        queue.sync { Self.reverbTime(envelope: envelope, hopSeconds: 0.01) }
    }

    /// Band level per bin (power x frequency, as the bins are log-spaced and wider at the top), minus the mid level.
    static func relativeBins(power: [Double], blocks: Int) -> [Float]? {
        guard blocks > 0 else { return nil }
        let levels = power.enumerated().map { index, value -> Double in
            10 * log10(max(value / Double(blocks) * EQSpectrum.frequency(ofBin: index), 1e-20))
        }
        let mids = levels.enumerated().filter { (500.0...2000.0).contains(EQSpectrum.frequency(ofBin: $0.offset)) }
            .map { pow(10, $0.element / 10) }
        guard !mids.isEmpty else { return nil }
        let reference = 10 * log10(mids.reduce(0, +) / Double(mids.count))
        return levels.map { Float($0 - reference) }
    }

    /// RT60 from the slope of the decay after the loudest point, between 5 and 25 dB below it (T20 x 3).
    static func reverbTime(envelope: [Float], hopSeconds: Double) -> Float? {
        guard envelope.count > 50,
              let peakIndex = envelope.indices.max(by: { envelope[$0] < envelope[$1] }) else { return nil }
        let peak = envelope[peakIndex]
        let floor = envelope.sorted()[envelope.count / 10]
        guard peak - floor >= 35 else { return nil }
        var xs: [Double] = []
        var ys: [Double] = []
        var index = peakIndex
        while index < envelope.count, envelope[index] > peak - 25 {
            if envelope[index] <= peak - 5 {
                xs.append(Double(index - peakIndex) * hopSeconds)
                ys.append(Double(envelope[index]))
            }
            index += 1
        }
        guard xs.count >= 8 else { return nil }
        let n = Double(xs.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        let covariance = zip(xs, ys).reduce(0.0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let variance = xs.reduce(0.0) { $0 + ($1 - meanX) * ($1 - meanX) }
        guard variance > 0 else { return nil }
        let slope = covariance / variance
        guard slope < -1 else { return nil }
        return Float(60 / -slope)
    }
}

/// Runs one measurement with the microphone while the room card is open.
@MainActor
@Observable
final class RoomMeter {
    enum Kind { case spectrum, reverb }
    enum State: Equatable {
        case idle, measuring
        case failed(String)
    }

    private(set) var state = State.idle
    private(set) var kind = Kind.spectrum
    private(set) var progress = 0.0
    private(set) var level: Float = -90
    private(set) var live: [Float] = []
    /// Set when a measurement finishes and has been saved.
    private(set) var result: RoomMeasurement?

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var analyzer: RoomAnalyzer?
    @ObservationIgnored private var task: Task<Void, Never>?

    var isMeasuring: Bool { state == .measuring }

    func start(_ kind: Kind) {
        guard !isMeasuring else { return }
        task = Task {
            let allowed = await AVAudioApplication.requestRecordPermission()
            guard allowed else {
                state = .failed(L("Microphone access is off. Allow it in Settings › Holly Mixer."))
                return
            }
            await measure(kind)
        }
    }

    func cancel() {
        task?.cancel()
        teardown()
        if isMeasuring { state = .idle }
    }

    private func measure(_ kind: Kind) async {
        self.kind = kind
        progress = 0
        live = []
        result = nil
        let seconds: Double = kind == .spectrum ? 20 : 8
        do {
            let session = AVAudioSession.sharedInstance()
            // Measurement mode switches off the automatic gain and voice processing a phone microphone normally applies.
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
            let engine = AVAudioEngine()
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                state = .failed(L("No microphone is available."))
                return
            }
            let analyzer = RoomAnalyzer(mode: kind == .spectrum ? .spectrum : .reverb, sampleRate: format.sampleRate)
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tap(analyzer))
            try engine.start()
            self.engine = engine
            self.analyzer = analyzer
            state = .measuring
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        let started = Date()
        while !Task.isCancelled, Date().timeIntervalSince(started) < seconds {
            try? await Task.sleep(for: .milliseconds(250))
            progress = min(Date().timeIntervalSince(started) / seconds, 1)
            if let analyzer {
                level = analyzer.currentLevel()
                if kind == .spectrum, let bins = analyzer.spectrum() { live = bins }
            }
        }
        guard !Task.isCancelled, let analyzer else { return }
        finish(kind, analyzer)
    }

    /// Built outside the main actor: the audio thread calls it.
    private nonisolated static func tap(_ analyzer: RoomAnalyzer) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            analyzer.feed(Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
        }
    }

    private func finish(_ kind: Kind, _ analyzer: RoomAnalyzer) {
        let rate = analyzer.sampleRate
        let bins = kind == .spectrum ? analyzer.spectrum() : nil
        let rt60 = kind == .reverb ? analyzer.reverbTime() : nil
        teardown()
        if kind == .spectrum {
            guard let bins else {
                state = .failed(L("Not enough sound was heard. Is the pink noise playing?"))
                return
            }
            result = RoomStore.merge(bins: bins, sampleRate: rate)
        } else {
            guard let rt60 else {
                state = .failed(L("No clear decay was found. Clap once, loudly, then stay quiet."))
                return
            }
            result = RoomStore.merge(rt60: rt60, sampleRate: rate)
        }
        state = .idle
    }

    private func teardown() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        analyzer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
