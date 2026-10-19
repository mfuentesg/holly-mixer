import Foundation
import Observation
import SwiftUI

/// Values of OSC addresses, split by type so the JSON stays small and unambiguous.
struct BackupValues: Codable, Equatable {
    var ints: [String: Int32] = [:]
    var floats: [String: Float] = [:]
    var strings: [String: String] = [:]

    var count: Int { ints.count + floats.count + strings.count }

    init(_ live: [String: OSCArgument] = [:]) {
        for (address, value) in live {
            switch value {
            case .int(let number): ints[address] = number
            case .float(let number): floats[address] = number
            case .string(let text): strings[address] = text
            case .blob: break
            }
        }
    }

    subscript(address: String) -> OSCArgument? {
        if let value = ints[address] { return .int(value) }
        if let value = floats[address] { return .float(value) }
        if let value = strings[address] { return .string(value) }
        return nil
    }

    var all: [(address: String, value: OSCArgument)] {
        ints.map { (address: $0.key, value: OSCArgument.int($0.value)) }
            + floats.map { (address: $0.key, value: OSCArgument.float($0.value)) }
            + strings.map { (address: $0.key, value: OSCArgument.string($0.value)) }
    }
}

/// A saved copy of everything Mixit knows about one mixer's settings.
struct MixerBackup: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var date: Date
    /// Made by the automatic backup (as opposed to "Save now").
    var isAuto: Bool
    var mixerName: String
    var firmware: String
    var values: BackupValues
}

/// One value that differs between a backup and the mixer.
struct BackupChange: Identifiable {
    var id: String { address }
    let address: String
    /// What the backup holds (what a restore would write).
    let saved: OSCArgument
    /// What the mixer has now.
    let live: OSCArgument

    /// Phantom power is never restored unless asked: switching +48V live can damage gear or pop.
    var isPhantom: Bool { address.hasSuffix("/phantom") }
}

/// A topic inside the diff, e.g. "Pulpito" with "EQ, gate".
struct BackupChangeGroup: Identifiable {
    let id: String
    let title: String
    let color: Color
    let topics: [String]
    let changes: [BackupChange]
}

/// The mixer differs from the last saved state: asks the user what to do.
struct PendingBackupDecision {
    let backup: MixerBackup
    let changes: [BackupChange]
}

/// Saves the mixer's settings on this device and notices when the mixer has lost them (for example
/// after a power cycle), so they can be put back. Files live in Documents/Backups/<mixer>/.
@MainActor
@Observable
final class BackupStore {
    static let shared = BackupStore()

    /// Newest first: the latest automatic backup, older automatic ones and the manual ones.
    private(set) var backups: [MixerBackup] = []
    /// Set when the mixer's settings differ a lot from the last backup; automatic saving waits for a decision.
    private(set) var pending: PendingBackupDecision?
    private(set) var lastAutoSave: Date?
    private(set) var isRestoring = false
    private(set) var restoreProgress = 0
    private(set) var restoreTotal = 0
    /// Short text shown in the backup page after an action ("Restored 143 values").
    var notice: String?

    var isAutoBackupOn: Bool {
        didSet { UserDefaults.standard.set(isAutoBackupOn, forKey: Self.enabledKey) }
    }

    /// At least this many different values count as "the mixer lost its settings".
    static let differenceThreshold = 8
    private static let enabledKey = "autoBackupEnabled"
    private static let historyLimit = 8
    private static let historySpacing: TimeInterval = 3600

    @ObservationIgnored private weak var mixer: Mixer?
    @ObservationIgnored private var key: String?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The backup stored in auto.json: the one automatic saving overwrites.
    @ObservationIgnored private var latestAutoID: UUID?

    init() {
        isAutoBackupOn = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    // MARK: - Attaching

    /// Starts watching a mixer. Call again on every launch of the mixer screen; it is cheap.
    func attach(_ mixer: Mixer) {
        guard self.mixer !== mixer || saveTask == nil else { return }
        self.mixer = mixer
        mixer.onValuesChanged = { [weak self] in self?.dirty = true }
        mixer.onFullState = { [weak self] in self?.mixerSynced() }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                self?.autosaveIfNeeded()
            }
        }
    }

    private func currentKey() -> String {
        guard let mixer else { return "mixer" }
        if mixer.isDemo { return "demo" }
        let cleaned = String(mixer.mixerName.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        return cleaned.isEmpty ? "mixer" : "mixer-\(cleaned)"
    }

    // MARK: - After the mixer answered

    private func mixerSynced() {
        guard let mixer else { return }
        key = currentKey()
        reload()
        dirty = false
        pending = nil
        guard let latest = backups.first(where: { $0.id == latestAutoID }) else {
            // First time with this mixer: its current state becomes the baseline.
            if isAutoBackupOn { writeAuto(from: mixer) }
            return
        }
        let changes = Self.differences(from: latest.values, to: mixer.liveValues)
        if changes.count >= Self.differenceThreshold {
            pending = PendingBackupDecision(backup: latest, changes: changes)
        } else if isAutoBackupOn {
            archiveLatestIfDue(latest)
            writeAuto(from: mixer)
        }
    }

    /// Values in `backup` that the mixer reports differently. Addresses the mixer didn't answer are ignored.
    static func differences(from backup: BackupValues, to live: [String: OSCArgument]) -> [BackupChange] {
        var found: [BackupChange] = []
        for item in backup.all {
            guard let now = live[item.address], !Self.same(item.value, now) else { continue }
            found.append(BackupChange(address: item.address, saved: item.value, live: now))
        }
        return found.sorted { $0.address < $1.address }
    }

    private static func same(_ a: OSCArgument, _ b: OSCArgument) -> Bool {
        switch (a, b) {
        case (.float(let x), .float(let y)): return abs(x - y) < 0.004
        default: return a == b
        }
    }

    // MARK: - Decisions

    /// Writes the saved values back to the mixer. Phantom power only when `includePhantom`.
    func restore(_ changes: [BackupChange], includePhantom: Bool) async {
        guard let mixer, !isRestoring else { return }
        let chosen = changes.filter { includePhantom || !$0.isPhantom }
        isRestoring = true
        restoreProgress = 0
        restoreTotal = chosen.count
        await mixer.writeValues(chosen.map { (address: $0.address, value: $0.saved) }) { [weak self] done in
            self?.restoreProgress = done
        }
        isRestoring = false
        notice = "Restored \(chosen.count) values to the mixer."
        pending = nil
        dirty = true
    }

    /// Restores a stored backup: everything that differs from the mixer right now.
    func restore(_ backup: MixerBackup, includePhantom: Bool) async {
        guard let mixer else { return }
        let changes = Self.differences(from: backup.values, to: mixer.liveValues)
        await restore(changes, includePhantom: includePhantom)
    }

    /// Differences between a backup and the live mixer (for the preview before restoring).
    func changes(for backup: MixerBackup) -> [BackupChange] {
        guard let mixer else { return [] }
        return Self.differences(from: backup.values, to: mixer.liveValues)
    }

    /// Accepts the mixer as it is now. The older automatic backup is kept in the history first.
    func keepMixerState() {
        guard let mixer else { return }
        if let latest = pending?.backup { archive(latest) }
        pending = nil
        if isAutoBackupOn { writeAuto(from: mixer) }
        notice = "Kept the mixer's current settings."
    }

    // MARK: - Manual backups

    @discardableResult
    func saveNow(name: String) -> MixerBackup? {
        guard let mixer, mixer.fullStateReady || mixer.isDemo else { return nil }
        key = currentKey()
        let backup = MixerBackup(name: name.isEmpty ? Self.defaultName() : name, date: Date(), isAuto: false,
                                 mixerName: mixer.mixerName, firmware: mixer.firmware,
                                 values: BackupValues(mixer.liveValues))
        write(backup, file: "manual-\(backup.id.uuidString).json")
        reload()
        notice = "Saved “\(backup.name)”."
        return backup
    }

    func rename(_ backup: MixerBackup, to name: String) {
        var copy = backup
        copy.name = name
        write(copy, file: file(for: backup))
        reload()
    }

    func delete(_ backup: MixerBackup) {
        if let url = url(file(for: backup)) { try? FileManager.default.removeItem(at: url) }
        reload()
    }

    /// The JSON file of a backup, for sharing or moving to another iPad.
    func exportURL(for backup: MixerBackup) -> URL? {
        url(file(for: backup))
    }

    /// Adds a backup file exported from another iPad as a manual backup.
    func importBackup(from fileURL: URL) {
        let access = fileURL.startAccessingSecurityScopedResource()
        defer { if access { fileURL.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: fileURL), var backup = Self.decode(data) else {
            notice = "That file isn't a Mixit backup."
            return
        }
        key = currentKey()
        backup.id = UUID()
        backup.isAuto = false
        write(backup, file: "manual-\(backup.id.uuidString).json")
        reload()
        notice = "Imported “\(backup.name)”."
    }

    // MARK: - Automatic saving

    private func autosaveIfNeeded() {
        guard dirty, isAutoBackupOn, pending == nil, let mixer, mixer.fullStateReady,
              mixer.status == .connected || mixer.isDemo else { return }
        // Never overwrite a good backup with a partial read.
        if let latest = backups.first(where: { $0.id == latestAutoID }), mixer.liveValues.count < latest.values.count / 2 { return }
        writeAuto(from: mixer)
    }

    private func writeAuto(from mixer: Mixer) {
        dirty = false
        key = currentKey()
        let backup = MixerBackup(name: "Automatic backup", date: Date(), isAuto: true,
                                 mixerName: mixer.mixerName, firmware: mixer.firmware,
                                 values: BackupValues(mixer.liveValues))
        write(backup, file: "auto.json")
        lastAutoSave = backup.date
        reload()
    }

    /// Copies the latest automatic backup into the history, at most once an hour.
    private func archiveLatestIfDue(_ latest: MixerBackup) {
        let newestHistory = backups.filter { $0.isAuto && $0.id != latest.id }.map(\.date).max()
        if let newestHistory, latest.date.timeIntervalSince(newestHistory) < Self.historySpacing { return }
        archive(latest)
    }

    private func archive(_ backup: MixerBackup) {
        var copy = backup
        copy.id = UUID()
        write(copy, file: "auto-\(copy.id.uuidString).json")
        // Keep the newest few.
        guard let directory else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let history = files.filter { $0.lastPathComponent.hasPrefix("auto-") }
            .compactMap { url -> (URL, Date)? in
                guard let data = try? Data(contentsOf: url), let item = Self.decode(data) else { return nil }
                return (url, item.date)
            }
            .sorted { $0.1 > $1.1 }
        for (url, _) in history.dropFirst(Self.historyLimit) { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Files

    private var directory: URL? {
        guard let key,
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documents.appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
    }

    private func url(_ file: String) -> URL? { directory?.appendingPathComponent(file) }

    private func file(for backup: MixerBackup) -> String {
        if backup.id == latestAutoID { return "auto.json" }
        return backup.isAuto ? "auto-\(backup.id.uuidString).json" : "manual-\(backup.id.uuidString).json"
    }

    private func write(_ backup: MixerBackup, file: String) {
        guard let directory, let url = url(file) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(backup) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func decode(_ data: Data) -> MixerBackup? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MixerBackup.self, from: data)
    }

    /// Reads all backup files of the current mixer, newest first.
    func reload() {
        key = key ?? currentKey()
        guard let directory else { backups = []; return }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let loaded = files.filter { $0.pathExtension == "json" }.compactMap { url -> (String, MixerBackup)? in
            guard let data = try? Data(contentsOf: url), let backup = Self.decode(data) else { return nil }
            return (url.lastPathComponent, backup)
        }
        latestAutoID = loaded.first { $0.0 == "auto.json" }?.1.id
        backups = loaded.map(\.1).sorted { $0.date > $1.date }
        lastAutoSave = backups.first(where: { $0.id == latestAutoID })?.date
    }

    private static func defaultName() -> String {
        "Saved " + Date().formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Describing changes

extension BackupStore {
    /// Groups changes by strip ("Pulpito: EQ, gate") for the review list.
    func groups(for changes: [BackupChange]) -> [BackupChangeGroup] {
        guard let mixer else { return [] }
        let strips = Dictionary((mixer.inputs + mixer.buses + mixer.fxSends + [mixer.main]).map { ($0.base, $0) },
                                uniquingKeysWith: { first, _ in first })
        var buckets: [String: [BackupChange]] = [:]
        var order: [String] = []
        for change in changes {
            let owner = Self.owner(of: change.address)
            if buckets[owner] == nil { order.append(owner) }
            buckets[owner, default: []].append(change)
        }
        return order.map { owner in
            let items = buckets[owner] ?? []
            let strip = strips[owner]
            let topics = Array(Set(items.map { Self.topic(of: $0.address) })).sorted()
            return BackupChangeGroup(id: owner, title: strip?.displayName ?? Self.readable(owner),
                                     color: strip?.color ?? Theme.textTertiary, topics: topics, changes: items)
        }
    }

    /// "/ch/01/eq/1/f" and "/headamp/01/gain" both belong to "/ch/01".
    static func owner(of address: String) -> String {
        let parts = address.split(separator: "/").map(String.init)
        if parts.first == "headamp", parts.count > 1, let number = Int(parts[1]) {
            return String(format: "/ch/%02d", number)
        }
        if parts.first == "lr" { return "/lr" }
        if parts.count > 2 { return "/\(parts[0])/\(parts[1])" }
        return "/config"
    }

    static func topic(of address: String) -> String {
        if address.contains("/headamp/") || address.contains("/preamp/") { return "preamp" }
        if address.contains("/eq/") { return "EQ" }
        if address.contains("/gate/") { return "gate" }
        if address.contains("/dyn/") { return "dynamics" }
        if address.contains("/config/name") || address.contains("/config/color") || address.contains("/config/icon") { return "name & color" }
        if address.contains("/config/") { return "config" }
        if address.contains("/mix/on") { return "mute" }
        if address.contains("/mix/fader") { return "fader" }
        if address.contains("/mix/") { return "sends & pan" }
        return "other"
    }

    private static func readable(_ owner: String) -> String {
        owner == "/config" ? "Mute groups & config" : owner
    }
}
