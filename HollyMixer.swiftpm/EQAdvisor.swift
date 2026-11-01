import Foundation

// The EQ assistant's logic: rule checks on the EQ in force, analysis of a recorded spectrum, the guard rails that
// every proposal goes through, and the request to Claude. No SwiftUI here. The same rules exist as Python tools in
// `tools/xr18_eq_audit.py`, `xr18_eq_record.py` and `xr18_eq_suggest.py`; keep them in step.

// MARK: - Roles

/// What a strip carries, which decides what a sensible EQ looks like.
enum EQRole: String, CaseIterable, Identifiable {
    case voice, guitar, bass, keys, drums, kick, talkback, playback, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .voice: return L("Voice")
        case .guitar: return L("Guitar")
        case .bass: return L("Bass")
        case .keys: return L("Keys")
        case .drums: return L("Drums")
        case .kick: return L("Kick")
        case .talkback: return L("Talkback (stage only)")
        case .playback: return L("Playback")
        case .other: return L("Other")
        }
    }

    /// The low cut usually used for this role, in Hz.
    var lowCutRange: ClosedRange<Float>? {
        switch self {
        case .kick: return 30...60
        case .bass: return 30...50
        case .drums: return 60...150
        case .voice: return 80...140
        case .guitar: return 80...120
        case .keys: return 40...100
        case .talkback: return 100...200
        case .playback, .other: return nil
        }
    }

    /// Keywords are written without accents; words of three letters or fewer must match a whole word of the name.
    private static let keywords: [(EQRole, [String])] = [
        (.kick, ["kick", "bombo", "bd"]),
        (.bass, ["bass", "bajo", "dib"]),
        (.drums, ["snare", "caja", "tom", "hat", "hh", "oh", "over", "drum", "bateria", "perc"]),
        (.voice, ["voz", "vox", "vocal", "coro", "lead", "pastor", "predic", "speak", "habla", "lider", "mic",
                  "cantante", "singer", "worship", "alab", "pulpito", "microf"]),
        (.guitar, ["gtr", "guit", "acou", "acus", "elec", "banjo", "uke"]),
        (.keys, ["keys", "tecl", "piano", "synth", "organ", "pad"]),
        (.talkback, ["talkback", "intercom", "comms"]),
        (.playback, ["track", "play", "laptop", "ipad", "dvd", "video", "usb", "click", "pista"]),
    ]

    static func guess(from name: String) -> EQRole {
        let folded = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let words = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        for (role, list) in keywords {
            for keyword in list {
                if keyword.count <= 3 {
                    // Short keywords must be a whole word, optionally numbered ("oh2"): "tom" must not match "Tomás".
                    let found = words.contains { word in
                        word == keyword || (word.hasPrefix(keyword) && word.dropFirst(keyword.count).allSatisfy(\.isNumber))
                    }
                    if found { return role }
                } else if folded.contains(keyword) {
                    return role
                }
            }
        }
        return .other
    }
}

/// The role the user picked for each strip (by OSC base address), kept on this device.
enum EQRoleStore {
    private static let key = "eqRoles"

    static func role(base: String, name: String) -> EQRole {
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: String]
        if let raw = stored?[base], let role = EQRole(rawValue: raw) { return role }
        return EQRole.guess(from: name)
    }

    static func set(_ role: EQRole, base: String) {
        var stored = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        stored[base] = role.rawValue
        UserDefaults.standard.set(stored, forKey: key)
    }
}

// MARK: - Snapshot and hints

/// A strip's EQ as the assistant looks at it.
struct EQSnapshot {
    var base: String
    var label: String
    var name: String
    var role: EQRole
    var isChannel: Bool
    var isBus: Bool
    var isMain: Bool
    var eqOn: Bool
    var lowCutOn: Bool?
    var lowCutHz: Float
    var bands: [EQBand]

    var hasLowCut: Bool { lowCutOn != nil }
}

struct EQHint: Identifiable {
    enum Level: Int { case note = 0, warning = 1, strong = 2 }
    let id = UUID()
    let level: Level
    let text: String
}

enum EQAdvisor {
    static let maxGain: Float = 6
    static let maxTotalBoost: Float = 9
    static let maxLowCut: Float = 250

    private static func hz(_ value: Float) -> String { ParamFormat.frequency(value) }
    private static func db(_ value: Float) -> String { ParamFormat.signed(value) }

    /// Rule checks on the EQ in force. Rules of thumb from the numbers alone: they say "look at", not "fix".
    static func hints(_ s: EQSnapshot) -> [EQHint] {
        var out: [EQHint] = []
        func add(_ level: EQHint.Level, _ text: String) { out.append(EQHint(level: level, text: text)) }

        let numbered = s.bands.enumerated().map { (number: $0.offset + 1, band: $0.element) }
        let active = numbered.filter { $0.band.type.hasGain && abs($0.band.gain) >= 0.5 }
        let boosts = active.filter { $0.band.gain > 0 }
        let isPeak: (EQBand) -> Bool = { $0.type == .parametric || $0.type == .vintage }

        if !s.eqOn && !active.isEmpty {
            add(.warning, L("EQ is off, so its \(active.count) set band(s) are not heard."))
        }

        if let lowCutOn = s.lowCutOn, s.isChannel {
            let range = s.role.lowCutRange
            if lowCutOn && s.lowCutHz <= 25 {
                add(.warning, L("The low cut is on at \(hz(s.lowCutHz)) Hz, its minimum: it filters nothing."))
            } else if lowCutOn && s.lowCutHz > 200 {
                add(.warning, L("The low cut at \(hz(s.lowCutHz)) Hz is very high: it thins everything below. Intended?"))
            } else if !lowCutOn, let range, s.role != .talkback {
                add(.warning, L("The low cut is off; for \(s.role.title) around \(hz(range.lowerBound))–\(hz(range.upperBound)) Hz usually helps."))
            } else if lowCutOn, let range,
                      !(range.lowerBound * 0.6...range.upperBound * 1.6).contains(s.lowCutHz) {
                add(.note, L("The low cut at \(hz(s.lowCutHz)) Hz is outside the usual \(hz(range.lowerBound))–\(hz(range.upperBound)) Hz for \(s.role.title)."))
            }
            if lowCutOn && s.lowCutHz >= 40 {
                for item in active where isPeak(item.band) && item.band.frequency < s.lowCutHz * 0.8
                    && abs(item.band.gain) >= 3 {
                    add(.warning, L("Band \(item.number) (\(db(item.band.gain)) dB at \(hz(item.band.frequency)) Hz) sits below the low cut: the filter works against it."))
                }
            }
        }

        for item in boosts {
            let band = item.band
            if band.gain >= 9 {
                add(.strong, L("Band \(item.number) boosts \(db(band.gain)) dB at \(hz(band.frequency)) Hz: very large. Cutting elsewhere is usually cleaner."))
            } else if band.gain >= 6 {
                add(.warning, L("Band \(item.number) boosts \(db(band.gain)) dB at \(hz(band.frequency)) Hz: large."))
            }
            if isPeak(band) && band.q >= 4 && band.gain >= 3 {
                add(.warning, L("Band \(item.number) is a narrow boost (Q \(ParamFormat.plain(band.q)), \(db(band.gain)) dB at \(hz(band.frequency)) Hz): it rings and invites feedback. Widen it or cut instead."))
            }
            if s.isChannel && isPeak(band) && band.frequency < 45 && band.gain >= 3
                && s.role != .kick && s.role != .bass {
                add(.warning, L("Band \(item.number) boosts \(db(band.gain)) dB at \(hz(band.frequency)) Hz: that is mostly rumble and eats headroom."))
            }
            if s.isBus && isPeak(band) && (1000...4000).contains(band.frequency) && band.gain >= 2 {
                add(.warning, L("Band \(item.number) boosts \(db(band.gain)) dB at \(hz(band.frequency)) Hz on a bus: if it feeds a stage monitor, that is the feedback zone. Prefer cutting."))
            }
        }

        for item in active where item.band.gain <= -10 {
            add(.warning, L("Band \(item.number) cuts \(db(item.band.gain)) dB at \(hz(item.band.frequency)) Hz: very deep. Often a mic or placement problem."))
        }

        let peakBoosts = boosts.filter { isPeak($0.band) }
        for (i, a) in peakBoosts.enumerated() {
            for b in peakBoosts.dropFirst(i + 1)
            where abs(log2(Double(a.band.frequency / b.band.frequency))) < 0.5 {
                add(.warning, L("Bands \(a.number) and \(b.number) both boost around \(hz(a.band.frequency)) Hz. One wider band does the same more cleanly."))
            }
        }

        if s.isMain {
            let total = boosts.reduce(Float(0)) { $0 + $1.band.gain }
            if total >= 6 {
                add(.warning, L("The main EQ adds \(db(total)) dB in total: less headroom and hard to undo. Cuts on the offending channels are safer."))
            }
        }
        return out.sorted { $0.level.rawValue > $1.level.rawValue }
    }
}

// MARK: - Spectrum

struct EQFinding: Identifiable {
    enum Kind { case peak, rumble, mud, harsh }
    let id = UUID()
    let kind: Kind
    let frequency: Float
    let text: String
}

/// The recorded RTA: 100 bins, assumed log-spaced from 20 Hz to 20 kHz (to be verified on the real mixer).
/// Field names encode to the same JSON the Python tools write (`mean_db`, `peak_db`).
struct EQSpectrum: Codable, Equatable {
    var meanDb: [Float]
    var peakDb: [Float]

    static let binCount = 100
    static let thirdOctaveCentres: [Double] = [25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500,
                                               630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300,
                                               8000, 10000, 12500, 16000]

    static func frequency(ofBin index: Int) -> Double {
        20 * pow(1000, (Double(index) + 0.5) / Double(binCount))
    }

    /// Power-averaged level (dB) per third-octave band.
    func thirdOctaves() -> [(hz: Double, db: Double)] {
        var out: [(hz: Double, db: Double)] = []
        let edge = pow(2, 1.0 / 6)
        for centre in Self.thirdOctaveCentres {
            var total = 0.0
            var count = 0
            for (index, value) in meanDb.enumerated() {
                let f = Self.frequency(ofBin: index)
                if f >= centre / edge && f < centre * edge {
                    total += pow(10, Double(value) / 10)
                    count += 1
                }
            }
            if count > 0 { out.append((centre, 10 * log10(max(total / Double(count), 1e-13)))) }
        }
        return out
    }

    private func level(_ low: Double, _ high: Double, in bands: [(hz: Double, db: Double)]) -> Double? {
        let powers = bands.filter { $0.hz >= low && $0.hz <= high }.map { pow(10, $0.db / 10) }
        guard !powers.isEmpty else { return nil }
        return 10 * log10(powers.reduce(0, +) / Double(powers.count))
    }

    /// Sustained narrow peaks (ringing), rumble, mud and harshness. Rules of thumb.
    func findings() -> [EQFinding] {
        let n = meanDb.count
        guard n == Self.binCount else { return [] }
        var out: [EQFinding] = []
        for index in 0..<n {
            let f = Self.frequency(ofBin: index)
            guard f >= 80 && f <= 12000 else { continue }
            let neighbours = ((max(0, index - 5))...(min(n - 1, index + 5))).filter { $0 != index }
                .map { meanDb[$0] }.sorted()
            let median = neighbours[neighbours.count / 2]
            let excess = meanDb[index] - median
            let isLocalMax = meanDb[index] >= meanDb[max(0, index - 1)] && meanDb[index] >= meanDb[min(n - 1, index + 1)]
            if excess >= 6 && isLocalMax {
                let text = L("Sustained narrow peak near \(ParamFormat.frequency(Float(f))) Hz (+\(Int(excess.rounded())) dB over its surroundings): ringing or a resonance.")
                out.append(EQFinding(kind: .peak, frequency: Float(f), text: text))
            }
        }
        let bands = thirdOctaves()
        if let mid = level(500, 2000, in: bands) {
            if let sub = level(25, 70, in: bands), sub - mid > 8 {
                out.append(EQFinding(kind: .rumble, frequency: 60,
                                     text: L("Energy below 70 Hz is \(Int((sub - mid).rounded())) dB above the mids: rumble. A low cut, or a higher one, should help.")))
            }
            if let mud = level(200, 400, in: bands), mud - mid > 6 {
                out.append(EQFinding(kind: .mud, frequency: 300,
                                     text: L("200–400 Hz is \(Int((mud - mid).rounded())) dB above the mids: boxy or muddy.")))
            }
            if let harsh = level(3000, 6300, in: bands), harsh - mid > 3 {
                out.append(EQFinding(kind: .harsh, frequency: 4000,
                                     text: L("3–6 kHz is \(Int((harsh - mid).rounded())) dB above the mids: harsh or sibilant.")))
            }
        }
        return out
    }
}

// MARK: - Proposals

struct EQProposedBand: Identifiable, Equatable {
    var band: Int
    var type: EQBandType
    var frequency: Float
    var gain: Float
    var q: Float
    var why: String
    var id: Int { band }
}

struct EQProposal: Equatable {
    enum Source { case rules, claude }
    var source: Source
    /// nil leaves the low cut as it is.
    var lowCutHz: Float?
    var bands: [EQProposedBand]
    var reasoning: String
    /// What the guard rails changed in the proposal.
    var notes: [String] = []

    var isEmpty: Bool { lowCutHz == nil && bands.isEmpty }
}

extension EQAdvisor {
    /// A conservative proposal from the findings, using only bands that are flat today.
    static func rulesProposal(_ s: EQSnapshot, findings: [EQFinding]) -> EQProposal {
        var free = s.bands.enumerated().filter { $0.element.type.hasGain && abs($0.element.gain) < 0.5 }
            .map { $0.offset + 1 }
        var bands: [EQProposedBand] = []
        var lowCut: Float?
        for finding in findings {
            switch finding.kind {
            case .rumble:
                if s.hasLowCut { lowCut = max(s.lowCutOn == true && s.lowCutHz > 25 ? s.lowCutHz * 1.5 : 80, 80) }
            case .peak, .mud, .harsh:
                guard !free.isEmpty else { continue }
                let (frequency, gain, q): (Float, Float, Float) = {
                    switch finding.kind {
                    case .mud: return (300, -2, 1)
                    case .harsh: return (4000, -2, 1.2)
                    default: return (finding.frequency, -3, 4)
                    }
                }()
                bands.append(EQProposedBand(band: free.removeFirst(), type: .parametric, frequency: frequency,
                                            gain: gain, q: q, why: finding.text))
            }
        }
        return sanitize(EQProposal(source: .rules, lowCutHz: lowCut, bands: bands,
                                   reasoning: L("From the recorded spectrum, with conservative rules. Only bands that are flat today are used.")),
                        for: s)
    }

    /// Clamps a proposal to what the strip can do and to the safety limits. Whatever the model says goes through this.
    static func sanitize(_ proposal: EQProposal, for s: EQSnapshot) -> EQProposal {
        var result = proposal
        var notes = proposal.notes

        if let cut = proposal.lowCutHz {
            if !s.hasLowCut || cut <= 0 {
                result.lowCutHz = nil
            } else {
                let clamped = min(max(cut, 20), maxLowCut)
                if clamped != cut { notes.append(L("Low cut limited to \(hz(clamped)) Hz.")) }
                result.lowCutHz = clamped
            }
        }

        var seen = Set<Int>()
        var bands: [EQProposedBand] = []
        for var band in proposal.bands {
            guard band.band >= 1, band.band <= s.bands.count, seen.insert(band.band).inserted else {
                notes.append(L("Band \(band.band) does not exist on this strip: ignored."))
                continue
            }
            if ![EQBandType.lowShelf, .parametric, .highShelf].contains(band.type) { band.type = .parametric }
            band.frequency = min(max(band.frequency, 20), 20000)
            band.q = min(max(band.q, 0.3), 10)
            if abs(band.gain) > maxGain {
                notes.append(L("Band \(band.band): \(db(band.gain)) dB limited to \(db(band.gain < 0 ? -maxGain : maxGain)) dB."))
                band.gain = band.gain < 0 ? -maxGain : maxGain
            }
            if s.isBus && band.gain > 0 && band.type != .highShelf && (1000...4000).contains(band.frequency) {
                notes.append(L("Band \(band.band): a boost in the feedback zone on a bus was removed."))
                band.gain = 0
            }
            bands.append(band)
        }
        let boost = bands.filter { $0.gain > 0 }.reduce(Float(0)) { $0 + $1.gain }
        if boost > maxTotalBoost {
            let scale = maxTotalBoost / boost
            bands = bands.map { var copy = $0; if copy.gain > 0 { copy.gain *= scale }; return copy }
            notes.append(L("Total boost \(db(boost)) dB scaled down to \(db(maxTotalBoost)) dB."))
        }
        result.bands = bands.map { var copy = $0; copy.gain = (copy.gain * 10).rounded() / 10; return copy }
        result.notes = notes
        return result
    }

    /// The strip's bands with the proposal laid over them, for drawing the "after" curve.
    static func bandsAfter(_ s: EQSnapshot, _ proposal: EQProposal) -> [EQBand] {
        var bands = s.bands
        for item in proposal.bands where bands.indices.contains(item.band - 1) {
            bands[item.band - 1] = EQBand(type: item.type, frequency: item.frequency, gain: item.gain, q: item.q)
        }
        return bands
    }
}

// MARK: - Applying

extension EQAdvisor {
    /// Writes a proposal to the mixer as ONE undo step, after saving a safety copy of the mixer's settings.
    @MainActor
    static func apply(_ proposal: EQProposal, strip: Strip, mixer: Mixer) {
        BackupStore.shared.saveSafety(reason: L("EQ suggestion"))
        let group = UUID()
        let label = L("\(strip.displayName) EQ suggestion")
        if !EQModel.isOn(mixer, strip) {
            mixer.set(XR18Params.eqOn(strip.base), .int(1), label: label, group: group)
        }
        if let cut = proposal.lowCutHz {
            mixer.set(XR18Params.preamp(strip.base, "hpf"), .float(XR18Params.lowCut.normalized(cut)),
                      label: label, group: group)
            mixer.set(XR18Params.preamp(strip.base, "hpon"), .int(1), label: label, group: group)
        }
        for band in proposal.bands {
            let number = band.band
            mixer.set(XR18Params.eq(strip.base, band: number, "type"), .int(Int32(band.type.rawValue)),
                      label: label, group: group)
            mixer.set(XR18Params.eq(strip.base, band: number, "f"),
                      .float(XR18Params.eqFrequency.normalized(band.frequency)), label: label, group: group)
            mixer.set(XR18Params.eq(strip.base, band: number, "g"),
                      .float(XR18Params.eqGain.normalized(band.gain)), label: label, group: group)
            if band.type.hasQ {
                mixer.set(XR18Params.eq(strip.base, band: number, "q"),
                          .float(XR18Params.eqQ.normalized(band.q)), label: label, group: group)
            }
        }
    }
}

extension EQModel {
    static func snapshot(_ mixer: Mixer, _ strip: Strip, role: EQRole) -> EQSnapshot {
        var isBus = false
        if case .bus = strip.kind { isBus = true }
        var isMain = false
        if case .main = strip.kind { isMain = true }
        return EQSnapshot(
            base: strip.base, label: strip.displayName, name: strip.name, role: role,
            isChannel: strip.isChannel, isBus: isBus, isMain: isMain,
            eqOn: isOn(mixer, strip),
            lowCutOn: strip.hasPreamp ? lowCutIsOn(mixer, strip) : nil,
            lowCutHz: strip.hasPreamp ? lowCutFrequency(mixer, strip) : 20,
            bands: bands(mixer, strip))
    }
}

// MARK: - Room

extension EQAdvisor {
    /// Third-octave levels of a room measurement (dB against the mids), limited to the range a device microphone
    /// can be trusted for.
    static func roomDeviations(_ bins: [Float]) -> [(hz: Double, db: Double)] {
        EQSpectrum(meanDb: bins, peakDb: bins).thirdOctaves().filter { $0.hz >= 63 && $0.hz <= 12500 }
    }

    private static func roomMean(_ bands: [(hz: Double, db: Double)], _ low: Double, _ high: Double) -> Double? {
        let powers = bands.filter { $0.hz >= low && $0.hz <= high }.map { pow(10, $0.db / 10) }
        guard !powers.isEmpty else { return nil }
        return 10 * log10(powers.reduce(0, +) / Double(powers.count))
    }

    /// Bands that stand out from their neighbours by 4 dB or more: resonances of the PA or the room.
    private static func roomPeaks(_ bands: [(hz: Double, db: Double)]) -> [(hz: Double, excess: Double)] {
        var out: [(hz: Double, excess: Double)] = []
        for index in bands.indices {
            let neighbours = bands.indices.filter { $0 != index && abs($0 - index) <= 3 }.map { bands[$0].db }
            guard neighbours.count >= 3 else { continue }
            let excess = bands[index].db - neighbours.reduce(0, +) / Double(neighbours.count)
            let isMax = (index == 0 || bands[index].db >= bands[index - 1].db)
                && (index == bands.count - 1 || bands[index].db >= bands[index + 1].db)
            if excess >= 4 && isMax { out.append((hz: bands[index].hz, excess: excess)) }
        }
        return out.sorted { $0.excess > $1.excess }
    }

    static func roomFindings(_ bins: [Float]) -> [String] {
        let bands = roomDeviations(bins)
        var out: [String] = []
        for peak in roomPeaks(bands).prefix(3) {
            out.append(L("Around \(hz(Float(peak.hz))) Hz the PA and room are \(Int(peak.excess.rounded())) dB above their neighbours: a resonance or a room mode."))
        }
        if let low = roomMean(bands, 63, 125), low > 6 {
            out.append(L("63–125 Hz is \(Int(low.rounded())) dB above the mids: the room reinforces the bass."))
        }
        if let high = roomMean(bands, 6300, 12500), high < -8 {
            out.append(L("6–12 kHz is \(Int((-high).rounded())) dB below the mids: dull (the microphone also rolls off up there)."))
        }
        return out
    }

    /// A conservative main EQ from the room measurement: cuts at resonances, a gentle shelf for bass build-up.
    static func roomProposal(_ s: EQSnapshot, bins: [Float]) -> EQProposal {
        let bands = roomDeviations(bins)
        var free = s.bands.enumerated().filter { $0.element.type.hasGain && abs($0.element.gain) < 0.5 }
            .map { $0.offset + 1 }
        var proposed: [EQProposedBand] = []
        if let low = roomMean(bands, 63, 125), low > 6, !free.isEmpty {
            proposed.append(EQProposedBand(
                band: free.removeFirst(), type: .lowShelf, frequency: 120, gain: Float(-min(low * 0.5, 4)), q: 1,
                why: L("63–125 Hz is \(Int(low.rounded())) dB above the mids: the room reinforces the bass.")))
        }
        for peak in roomPeaks(bands).prefix(3) {
            guard !free.isEmpty else { break }
            proposed.append(EQProposedBand(
                band: free.removeFirst(), type: .parametric, frequency: Float(peak.hz),
                gain: Float(-min(peak.excess * 0.6, 6)), q: 3,
                why: L("Around \(hz(Float(peak.hz))) Hz the PA and room are \(Int(peak.excess.rounded())) dB above their neighbours: a resonance or a room mode.")))
        }
        if let high = roomMean(bands, 6300, 12500), high < -8, !free.isEmpty {
            proposed.append(EQProposedBand(
                band: free.removeFirst(), type: .highShelf, frequency: 8000, gain: Float(min(-high * 0.3, 3)), q: 1,
                why: L("6–12 kHz is \(Int((-high).rounded())) dB below the mids: dull (the microphone also rolls off up there).")))
        }
        return sanitize(EQProposal(source: .rules, lowCutHz: nil, bands: proposed,
                                   reasoning: L("From the measurement at the listening spot: cuts first, small boosts. Check by ear and measure again.")),
                        for: s)
    }
}

// MARK: - Claude

enum EQAIError: LocalizedError {
    case noKey, refused, truncated, unreadable
    case network(String)
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .noKey: return L("Add your Claude API key first.")
        case .refused: return L("Claude declined this request.")
        case .truncated: return L("The answer was cut off. Try again.")
        case .unreadable: return L("Claude's answer could not be read.")
        case .network(let text): return L("Cannot reach Claude: \(text)")
        case .server(let code, let text): return L("Claude returned an error (\(code)): \(text)")
        }
    }
}

/// Asks Claude for a proposed EQ. Sends only the strip's name and role, its EQ, the spectrum summary and the user's
/// goal: never the mixer's address or name, and never a backup.
enum EQClaude {
    static let model = "claude-opus-5-5"

    private static func bandName(_ type: EQBandType) -> String {
        switch type {
        case .lowCut: return "low cut"
        case .lowShelf: return "low shelf"
        case .parametric: return "peak"
        case .vintage: return "vintage"
        case .highShelf: return "high shelf"
        case .highCut: return "high cut"
        }
    }

    /// The JSON the model sees. Shown to the user before anything is sent.
    static func payload(_ s: EQSnapshot, spectrum: EQSpectrum?, findings: [EQFinding], goal: String,
                        room: RoomMeasurement? = nil) -> String {
        var strip: [String: Any] = [
            "strip": s.base, "name": s.name, "role": s.role.rawValue, "band_count": s.bands.count,
            "eq_on": s.eqOn,
            "bands": s.bands.enumerated().map { (index, band) -> [String: Any] in
                ["band": index + 1, "type": bandName(band.type), "hz": Int(band.frequency.rounded()),
                 "gain_db": Double((band.gain * 10).rounded() / 10), "q": Double((band.q * 100).rounded() / 100)]
            },
        ]
        if let on = s.lowCutOn {
            let cut: [String: Any] = ["on": on, "hz": Int(s.lowCutHz.rounded())]
            strip["low_cut"] = cut
        }
        if let spectrum {
            let bands = spectrum.thirdOctaves()
            let top = bands.map(\.db).max() ?? 0
            var relative: [String: Double] = [:]
            for item in bands { relative[String(format: "%g", item.hz)] = ((item.db - top) * 10).rounded() / 10 }
            let recording: [String: Any] = ["third_octave_db_rel_max": relative, "local_findings": findings.map(\.text)]
            strip["recording"] = recording
        } else {
            strip["recording"] = NSNull()
        }
        var root: [String: Any] = ["strips": [strip]]
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { root["goal"] = String(trimmed.prefix(200)) }
        if let room {
            var info: [String: Any] = [:]
            if let bins = room.bins {
                var relative: [String: Double] = [:]
                for item in EQAdvisor.roomDeviations(bins) { relative[String(format: "%g", item.hz)] = (item.db * 10).rounded() / 10 }
                info["pa_and_room_third_octave_db_vs_mids"] = relative
            }
            if let rt60 = room.rt60 { info["rt60_seconds"] = Double((rt60 * 10).rounded() / 10) }
            if !info.isEmpty { root["room"] = info }
        }
        let data = (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static var system: String {
        let language = ActiveLanguage.code == "es" ? "Spanish" : "English"
        return """
        You are an assistant for a live-sound engineer at a small church using a Behringer XR18 mixer. \
        You propose EQ settings for the strip you are given. Rules:
        - Be conservative. Prefer cuts to boosts; keep each band within +/-6 dB and the total boost small.
        - Return the proposed low cut (low_cut_hz, 0 = leave it) and only the bands you want to change. \
        Only use band numbers the strip has ("band_count").
        - Band types: "low shelf", "peak", "high shelf". Frequencies 20-20000 Hz, Q 0.3-10 (Q only matters for peak).
        - Use the evidence: the recorded third-octave spectrum (dB relative to the loudest band), the local \
        findings, the role and the current EQ. Without a recording, keep changes small and say confidence is low. \
        Do not invent measurements.
        - Voices need clarity (cut mud around 200-400 Hz, presence 2-5 kHz). Monitors (buses) must avoid boosts \
        around 1-4 kHz because of feedback. The main EQ should stay nearly flat. "talkback" is not in the PA.
        - If "room" is present it was measured with a device microphone where the audience sits: \
        "pa_and_room_third_octave_db_vs_mids" is the PA plus room response to pink noise (positive = too much, \
        0 = flat; trust it only between 63 Hz and 12.5 kHz) and "rt60_seconds" is the reverberation time. Use it for \
        the main EQ; on a reverberant room (long RT60) keep low-mids tight and avoid boosting highs on channels. \
        Never try to fix room modes on individual channels.
        - Do not call settings wrong if they may be intentional; explain what the numbers show.
        - Write "why", "reasoning" and "summary" in \(language), short and concrete (frequency, amount, reason).
        """
    }

    private static var schema: [String: Any] {
        let band: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "required": ["band", "type", "hz", "gain_db", "q", "why"],
            "properties": [
                "band": ["type": "integer"],
                "type": ["type": "string", "enum": ["low shelf", "peak", "high shelf"]],
                "hz": ["type": "number"], "gain_db": ["type": "number"], "q": ["type": "number"],
                "why": ["type": "string"],
            ],
        ]
        let item: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "required": ["strip", "low_cut_hz", "bands", "reasoning"],
            "properties": [
                "strip": ["type": "string"], "low_cut_hz": ["type": "number"], "reasoning": ["type": "string"],
                "bands": ["type": "array", "items": band],
            ],
        ]
        return [
            "type": "object", "additionalProperties": false, "required": ["summary", "strips"],
            "properties": ["summary": ["type": "string"], "strips": ["type": "array", "items": item]],
        ]
    }

    private struct Answer: Decodable {
        struct Item: Decodable {
            struct Band: Decodable {
                let band: Int
                let type: String
                let hz: Double
                let gainDb: Double
                let q: Double
                let why: String
            }
            let strip: String
            let lowCutHz: Double
            let reasoning: String
            let bands: [Band]
        }
        let summary: String
        let strips: [Item]
    }

    private struct Reply: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let stopReason: String?
        let content: [Block]
    }

    /// Asks the model and returns a proposal (not yet through the guard rails) plus the model's summary.
    static func ask(payload: String, apiKey: String, snapshot: EQSnapshot) async throws -> (EQProposal, String) {
        guard !apiKey.isEmpty else { throw EQAIError.noKey }
        let body: [String: Any] = [
            "model": model, "max_tokens": 16000, "system": system,
            "messages": [["role": "user", "content": payload]],
            "output_config": ["effort": "high", "format": ["type": "json_schema", "schema": schema]],
        ]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw EQAIError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw EQAIError.server(http.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let reply = try? decoder.decode(Reply.self, from: data) else { throw EQAIError.unreadable }
        if reply.stopReason == "refusal" { throw EQAIError.refused }
        if reply.stopReason == "max_tokens" { throw EQAIError.truncated }
        let text = reply.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        guard let answer = try? decoder.decode(Answer.self, from: Data(text.utf8)) else { throw EQAIError.unreadable }
        guard let item = answer.strips.first(where: { $0.strip == snapshot.base }) ?? answer.strips.first else {
            throw EQAIError.unreadable
        }
        let bands = item.bands.map { band -> EQProposedBand in
            let type: EQBandType = band.type == "low shelf" ? .lowShelf : (band.type == "high shelf" ? .highShelf : .parametric)
            return EQProposedBand(band: band.band, type: type, frequency: Float(band.hz), gain: Float(band.gainDb),
                                  q: Float(band.q), why: band.why)
        }
        let proposal = EQProposal(source: .claude, lowCutHz: item.lowCutHz > 0 ? Float(item.lowCutHz) : nil,
                                  bands: bands, reasoning: item.reasoning)
        return (EQAdvisor.sanitize(proposal, for: snapshot), answer.summary)
    }
}
