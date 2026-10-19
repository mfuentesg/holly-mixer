import Foundation
import Observation

/// The order of service: scenes captured from the mixer, previewed against the live state and recalled.
/// One show file per mixer name (the demo mixer has its own), stored as JSON in Documents/Shows.
@MainActor
@Observable
final class SceneStore {
    /// Shared by the page and the mixer header.
    static let shared = SceneStore()

    private(set) var show = Show.empty(name: "Show")
    /// The scene whose recall preview is open.
    var selectedSceneID: UUID?
    /// Set for 10 minutes after a recall.
    private(set) var undoState: SceneUndoState?
    private(set) var isFading = false
    /// "Fade faders over 2 s" in the recall preview.
    var fadeFaders = true

    @ObservationIgnored private weak var mixer: Mixer?
    @ObservationIgnored private var loadedKey: String?
    @ObservationIgnored private var fadeTask: Task<Void, Never>?
    @ObservationIgnored private var undoExpiry: Task<Void, Never>?
    @ObservationIgnored private var seedTask: Task<Void, Never>?

    /// A recall can be undone for this long.
    static let undoWindow: TimeInterval = 600
    private static let fadeDuration: TimeInterval = 2
    private static let fadeSteps = 30
    /// A strip with a meter above this level (dBFS) counts as live.
    static let liveThreshold: Float = -30

    // MARK: - Attaching to a mixer

    /// Loads the show file that belongs to this mixer. Cheap to call repeatedly.
    func attach(_ mixer: Mixer) {
        self.mixer = mixer
        let key = Self.fileKey(for: mixer)
        if key != loadedKey {
            fadeTask?.cancel()
            fadeTask = nil
            isFading = false
            loadedKey = key
            selectedSceneID = nil
            clearUndo()
            show = load(key: key) ?? Show.empty(name: Self.showName(for: mixer))
        }
        scheduleDemoSeed()
    }

    private static func fileKey(for mixer: Mixer) -> String {
        if mixer.isDemo { return "demo" }
        let cleaned = String(mixer.mixerName.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        return cleaned.isEmpty ? "mixer" : "mixer-\(cleaned)"
    }

    private static func showName(for mixer: Mixer) -> String {
        if mixer.isDemo { return "Demo" }
        return mixer.mixerName.isEmpty ? L("Mixer") : mixer.mixerName
    }

    // MARK: - Reading

    var allScenes: [ShowScene] { show.scenes }

    func scene(_ id: UUID?) -> ShowScene? {
        guard let id else { return nil }
        return allScenes.first { $0.id == id }
    }

    func index(of id: UUID?) -> Int? {
        guard let id else { return nil }
        return allScenes.firstIndex { $0.id == id }
    }

    /// "03" for the third scene in the order of service.
    func number(of id: UUID?) -> String {
        guard let index = index(of: id) else { return "" }
        return String(format: "%02d", index + 1)
    }

    /// "03 · Worship"
    func label(of scene: ShowScene) -> String {
        "\(number(of: scene.id)) · \(scene.name)"
    }

    var currentScene: ShowScene? { scene(show.currentSceneID) }

    /// The scene after the live one (the first scene when none is live yet).
    var nextScene: ShowScene? {
        let list = allScenes
        guard let current = index(of: show.currentSceneID) else { return list.first }
        return current + 1 < list.count ? list[current + 1] : nil
    }

    var previousScene: ShowScene? {
        let list = allScenes
        guard let current = index(of: show.currentSceneID), current > 0 else { return nil }
        return list[current - 1]
    }

    /// The scene a step forward (+1) or back (-1) would select, relative to the open preview or the live scene.
    func stepTarget(_ delta: Int) -> ShowScene? {
        let list = allScenes
        guard !list.isEmpty else { return nil }
        let target: Int
        if let anchor = index(of: selectedSceneID) ?? index(of: show.currentSceneID) {
            target = anchor + delta
        } else {
            target = delta > 0 ? 0 : list.count - 1
        }
        return list.indices.contains(target) ? list[target] : nil
    }

    /// Opens the recall preview of the next or previous scene. Never recalls by itself.
    func previewStep(_ delta: Int) {
        if let target = stepTarget(delta) {
            selectedSceneID = target.id
        }
    }

    var canUndo: Bool { undoState != nil }

    var lastSavedText: String {
        show.savedAt.hollyMixer(date: .omitted, time: .shortened)
    }

    // MARK: - Capture

    private var allStrips: [Strip] {
        guard let mixer else { return [] }
        return mixer.inputs + mixer.buses + mixer.fxSends + [mixer.main]
    }

    /// A copy of the live mixer state.
    func capture() -> SceneSnapshot? {
        guard let mixer else { return nil }
        let strips = allStrips.map { strip in
            SceneStripState(base: strip.base, fader: strip.fader, isOn: strip.isOn,
                            pan: strip.hasPan ? strip.pan : nil, sends: strip.sends)
        }
        return SceneSnapshot(strips: strips, muteGroups: mixer.muteGroups)
    }

    // MARK: - Diff

    private static func differs(_ a: Float, _ b: Float) -> Bool {
        abs(a - b) > 0.001
    }

    private static func formatPan(_ value: Float) -> String {
        let percent = Int(((value - 0.5) * 200).rounded())
        if percent == 0 { return "C" }
        return percent < 0 ? "L\(-percent)" : "R\(percent)"
    }

    /// The differences between the live mixer and a snapshot. With `applyingSafes` the recall safes
    /// of the show are respected and counted in `keptSafe`.
    func diff(to snapshot: SceneSnapshot, applyingSafes: Bool = true) -> SceneDiff {
        guard let mixer else { return SceneDiff() }
        let safes = applyingSafes ? show.safes : RecallSafes()
        var result = SceneDiff()
        for strip in allStrips {
            guard let target = snapshot.state(for: strip.base) else { continue }
            var found: [SceneChange] = []
            var skipped = safes.strips.contains(strip.base)
            if case .bus(let number) = strip.kind, safes.buses.contains(number) { skipped = true }
            collectOwnChanges(strip, target, into: &found)
            if skipped {
                result.keptSafe += found.count
                found = []
            }
            result.changes.append(contentsOf: found)
            for index in 0..<min(strip.sends.count, target.sends.count)
            where Self.differs(strip.sends[index], target.sends[index]) {
                let destination: Strip = index < 6 ? mixer.buses[index] : mixer.fxSends[index - 6]
                if skipped || (index < 6 && safes.buses.contains(index + 1)) {
                    result.keptSafe += 1
                    continue
                }
                result.changes.append(SceneChange(
                    id: "send:\(strip.base):\(index)", group: .sends,
                    name: "\(strip.displayName) → \(destination.displayName)", color: strip.color,
                    from: formatDecibels(strip.sends[index]), to: formatDecibels(target.sends[index]),
                    tone: target.sends[index] > strip.sends[index] ? .up : .down,
                    action: .send(base: strip.base, index: index, to: target.sends[index])))
            }
        }
        for number in 1...4 {
            let engaged = snapshot.muteGroups[safe: number - 1] ?? false
            guard mixer.muteGroups[number - 1] != engaged else { continue }
            result.changes.append(SceneChange(
                id: "mg:\(number)", group: .mutes, name: L("Mute group \(number)"), color: Theme.textTertiary,
                from: engaged ? L("off") : L("on"), to: engaged ? L("on") : L("off"),
                tone: engaged ? .muted : .onAir, action: .muteGroup(number: number, isOn: engaged)))
        }
        return result
    }

    /// Fader, mute and pan differences of one strip.
    private func collectOwnChanges(_ strip: Strip, _ target: SceneStripState, into found: inout [SceneChange]) {
        if Self.differs(strip.fader, target.fader) {
            let tone: SceneChangeTone = target.fader > strip.fader ? .up : .down
            found.append(SceneChange(
                id: "fader:\(strip.base)", group: .faders, name: strip.displayName, color: strip.color,
                from: formatDecibels(strip.fader), to: formatDecibels(target.fader), tone: tone,
                action: .fader(base: strip.base, from: strip.fader, to: target.fader)))
        }
        if strip.isOn != target.isOn {
            found.append(SceneChange(
                id: "mute:\(strip.base)", group: .mutes, name: strip.displayName, color: strip.color,
                from: strip.isOn ? L("on air") : L("MUTED"), to: target.isOn ? L("on air") : L("MUTED"),
                tone: target.isOn ? .onAir : .muted, action: .mute(base: strip.base, isOn: target.isOn)))
        }
        if strip.hasPan, let pan = target.pan, Self.differs(strip.pan, pan) {
            found.append(SceneChange(
                id: "pan:\(strip.base)", group: .pan, name: strip.displayName, color: strip.color,
                from: Self.formatPan(strip.pan), to: Self.formatPan(pan), tone: .neutral,
                action: .pan(base: strip.base, to: pan)))
        }
    }

    /// Channels with signal that these changes would mute or pull to −∞.
    func warnings(for changes: [SceneChange]) -> [SceneWarning] {
        var seen = Set<String>()
        var warnings: [SceneWarning] = []
        for change in changes {
            let base: String
            let action: String
            switch change.action {
            case .fader(let changeBase, let from, let to):
                guard to <= 0.0005, from > 0.0005 else { continue }
                base = changeBase
                action = L("pulls it to −∞")
            case .mute(let changeBase, let isOn):
                guard !isOn else { continue }
                base = changeBase
                action = L("mutes it")
            default:
                continue
            }
            guard !seen.contains(base), let strip = allStrips.first(where: { $0.base == base }),
                  strip.isOn, strip.fader > 0.0005, strip.meter > Self.liveThreshold else { continue }
            seen.insert(base)
            warnings.append(SceneWarning(id: base, name: strip.displayName, level: strip.meter, action: action))
        }
        return warnings
    }

    // MARK: - Recall

    /// Applies exactly the differing values of a scene. Faders can fade over 2 s.
    func recall(_ sceneID: UUID, fade: Bool) {
        guard let scene = scene(sceneID), let before = capture() else { return }
        let changes = diff(to: scene.snapshot).changes
        BackupStore.shared.saveSafety(reason: L("scene \(label(of: scene))"))
        setUndo(SceneUndoState(snapshot: before, previousSceneID: show.currentSceneID,
                               sceneLabel: label(of: scene), date: Date()))
        apply(changes, fade: fade)
        show.currentSceneID = sceneID
        selectedSceneID = nil
        commit()
    }

    /// Puts the mixer back as it was before the last recall (within 10 minutes).
    func undoRecall() {
        guard let undo = undoState, Date().timeIntervalSince(undo.date) < Self.undoWindow else {
            clearUndo()
            return
        }
        apply(diff(to: undo.snapshot, applyingSafes: false).changes, fade: false)
        show.currentSceneID = scene(undo.previousSceneID) == nil ? nil : undo.previousSceneID
        clearUndo()
        commit()
    }

    private func setUndo(_ state: SceneUndoState) {
        undoState = state
        undoExpiry?.cancel()
        undoExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.undoWindow))
            guard !Task.isCancelled else { return }
            self?.undoState = nil
        }
    }

    private func clearUndo() {
        undoExpiry?.cancel()
        undoExpiry = nil
        undoState = nil
    }

    /// Writes the changes to the mixer. A running fade is cancelled first. When fading, mutes are
    /// applied after the fade ends, and unmutes before it starts.
    private func apply(_ changes: [SceneChange], fade: Bool) {
        guard let mixer else { return }
        fadeTask?.cancel()
        fadeTask = nil
        isFading = false
        let strips = Dictionary(allStrips.map { ($0.base, $0) }, uniquingKeysWith: { first, _ in first })
        var fades: [(strip: Strip, from: Float, to: Float)] = []
        var lateMutes: [String] = []
        for change in changes {
            switch change.action {
            case .fader(let base, let from, let to):
                guard let strip = strips[base] else { continue }
                if fade {
                    fades.append((strip, from, to))
                } else {
                    mixer.setLevel(strip, .fader, to: to)
                }
            case .mute(let base, let isOn):
                if fade && !isOn {
                    lateMutes.append(base)
                } else {
                    mixer.set("\(base)/mix/on", .int(isOn ? 1 : 0))
                }
            case .send(let base, let index, let to):
                if let strip = strips[base] { mixer.setLevel(strip, .send(index), to: to) }
            case .pan(let base, let to):
                mixer.set("\(base)/mix/pan", .float(to))
            case .muteGroup(let number, let isOn):
                mixer.set("/config/mute/\(number)", .int(isOn ? 1 : 0))
            }
        }
        guard fade, !(fades.isEmpty && lateMutes.isEmpty) else { return }
        isFading = true
        fadeTask = Task { [weak self] in
            let steps = Self.fadeSteps
            let pause = Duration.milliseconds(Int(Self.fadeDuration * 1000) / steps)
            for step in 1...steps {
                try? await Task.sleep(for: pause)
                if Task.isCancelled { return }
                let progress = Float(step) / Float(steps)
                for item in fades {
                    let value = step == steps ? item.to : item.from + (item.to - item.from) * progress
                    mixer.setLevel(item.strip, .fader, to: value)
                }
            }
            for base in lateMutes {
                mixer.set("\(base)/mix/on", .int(0))
            }
            self?.isFading = false
        }
    }

    // MARK: - Editing the show

    /// Saves the live mixer state as a new scene at the end of a section. It becomes the live scene.
    @discardableResult
    func addScene(name: String, note: String, sectionID: UUID) -> UUID? {
        guard let snapshot = capture(), let section = show.sections.firstIndex(where: { $0.id == sectionID }) else {
            return nil
        }
        let scene = ShowScene(name: name, note: note, snapshot: snapshot)
        show.sections[section].scenes.append(scene)
        show.currentSceneID = scene.id
        commit()
        return scene.id
    }

    /// Renames a scene and moves it to the end of another section if `sectionID` differs.
    func update(_ sceneID: UUID, name: String, note: String, sectionID: UUID) {
        guard let (sectionIndex, sceneIndex) = location(of: sceneID) else { return }
        var scene = show.sections[sectionIndex].scenes[sceneIndex]
        scene.name = name
        scene.note = note
        if show.sections[sectionIndex].id == sectionID {
            show.sections[sectionIndex].scenes[sceneIndex] = scene
        } else if let target = show.sections.firstIndex(where: { $0.id == sectionID }) {
            show.sections[sectionIndex].scenes.remove(at: sceneIndex)
            show.sections[target].scenes.append(scene)
        }
        commit()
    }

    /// Replaces a scene's stored state with the live mixer state.
    func overwriteWithCurrent(_ sceneID: UUID) {
        guard let (sectionIndex, sceneIndex) = location(of: sceneID), let snapshot = capture() else { return }
        show.sections[sectionIndex].scenes[sceneIndex].snapshot = snapshot
        show.sections[sectionIndex].scenes[sceneIndex].savedAt = Date()
        commit()
    }

    func deleteScene(_ sceneID: UUID) {
        guard let (sectionIndex, sceneIndex) = location(of: sceneID) else { return }
        show.sections[sectionIndex].scenes.remove(at: sceneIndex)
        if show.currentSceneID == sceneID { show.currentSceneID = nil }
        if selectedSceneID == sceneID { selectedSceneID = nil }
        commit()
    }

    /// Moves a scene one place earlier (-1) or later (+1) inside its section.
    func moveScene(_ sceneID: UUID, by delta: Int) {
        guard let (sectionIndex, sceneIndex) = location(of: sceneID) else { return }
        let target = sceneIndex + delta
        guard show.sections[sectionIndex].scenes.indices.contains(target) else { return }
        show.sections[sectionIndex].scenes.swapAt(sceneIndex, target)
        commit()
    }

    func canMoveScene(_ sceneID: UUID, by delta: Int) -> Bool {
        guard let (sectionIndex, sceneIndex) = location(of: sceneID) else { return false }
        return show.sections[sectionIndex].scenes.indices.contains(sceneIndex + delta)
    }

    func sectionID(of sceneID: UUID) -> UUID? {
        location(of: sceneID).map { show.sections[$0.section].id }
    }

    private func location(of sceneID: UUID) -> (section: Int, scene: Int)? {
        for (sectionIndex, section) in show.sections.enumerated() {
            if let sceneIndex = section.scenes.firstIndex(where: { $0.id == sceneID }) {
                return (sectionIndex, sceneIndex)
            }
        }
        return nil
    }

    func setBusSafe(_ number: Int, _ isSafe: Bool) {
        if isSafe { show.safes.buses.insert(number) } else { show.safes.buses.remove(number) }
        commit()
    }

    func setStripSafe(_ base: String, _ isSafe: Bool) {
        if isSafe { show.safes.strips.insert(base) } else { show.safes.strips.remove(base) }
        commit()
    }

    // MARK: - Persistence

    private static var directory: URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documents.appendingPathComponent("Shows", isDirectory: true)
    }

    private func url(for key: String) -> URL? {
        Self.directory?.appendingPathComponent("\(key).json")
    }

    private func load(key: String) -> Show? {
        guard let url = url(for: key), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Show.self, from: data)
    }

    /// Writes the show file. Without a known mixer nothing is written.
    private func commit() {
        show.savedAt = Date()
        guard let key = loadedKey, let directory = Self.directory, let url = url(for: key) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(show) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Demo show

    private func scheduleDemoSeed() {
        seedTask?.cancel()
        guard let mixer, mixer.isDemo, show.scenes.isEmpty else { return }
        let key = loadedKey
        seedTask = Task { [weak self] in
            // Give the demo mixer a moment to answer the initial state requests.
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self, let mixer = self.mixer, mixer.isDemo,
                  mixer.status == .connected, self.loadedKey == key, self.show.scenes.isEmpty else { return }
            self.seedDemoShow()
        }
    }

    /// The example show from the design, built from the current demo state (which is scene 03).
    private func seedDemoShow() {
        guard let worship = capture() else { return }
        var walkIn = worship
        for channel in 1...16 { walkIn.edit(String(format: "/ch/%02d", channel), isOn: false) }
        walkIn.edit("/rtn/aux", faderDecibels: -4, isOn: true)

        var announcements = walkIn
        announcements.edit("/ch/01", faderDecibels: 5, isOn: true)
        announcements.edit("/rtn/aux", isOn: false)

        var sermon = worship
        sermon.edit("/ch/01", faderDecibels: 9)
        sermon.edit("/ch/05", faderDecibels: -Float.infinity)
        sermon.edit("/ch/02", faderDecibels: -10)
        sermon.edit("/ch/03", faderDecibels: -20)
        sermon.edit("/lr", faderDecibels: -3)
        for base in ["/ch/10", "/ch/04", "/ch/08", "/ch/11"] { sermon.edit(base, isOn: false) }
        sermon.edit("/ch/10", sendIndex: 1, sendDecibels: -Float.infinity)
        sermon.edit("/ch/04", sendIndex: 1, sendDecibels: -Float.infinity)
        sermon.edit("/ch/10", sendIndex: 2, sendDecibels: -Float.infinity)
        sermon.edit("/ch/04", sendIndex: 2, sendDecibels: -Float.infinity)

        var response = worship
        for base in ["/ch/01", "/ch/10", "/ch/04", "/ch/08", "/ch/11", "/ch/03"] { response.edit(base, isOn: false) }

        var walkOut = walkIn
        walkOut.edit("/rtn/aux", faderDecibels: -2)

        func scene(_ name: String, _ note: String, _ snapshot: SceneSnapshot) -> ShowScene {
            ShowScene(name: name, note: note, snapshot: snapshot)
        }
        let worshipScene = scene("Worship", "Full band · 4 vox", worship)
        var demo = Show.empty(name: "Demo")
        demo.sections[0].scenes = [scene("Walk-in", "Playback · lobby on", walkIn),
                                   scene("Announcements", "Pulpito + video", announcements)]
        demo.sections[1].scenes = [worshipScene]
        demo.sections[2].scenes = [scene("Sermon", "Pulpito only · band muted", sermon)]
        demo.sections[3].scenes = [scene("Response", "Keys + 2 vox", response)]
        demo.sections[4].scenes = [scene("Walk-out", "Playback · stream fade", walkOut)]
        demo.currentSceneID = worshipScene.id
        demo.safes.buses = [2, 3]
        show = demo
        commit()
    }
}

private extension Array {
    /// The element at `index`, or nil when out of range.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
