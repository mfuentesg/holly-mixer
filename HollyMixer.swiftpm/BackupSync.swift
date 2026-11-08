import Foundation

/// Keeps the saved backups of several devices the same by mirroring them into a folder the user picked in the
/// Files app (normally in iCloud Drive; any folder that syncs between the devices works).
///
/// Why a folder and not the iCloud container: this is a Swift Playgrounds package, which cannot declare the
/// iCloud entitlement. A folder chosen through the document picker needs no entitlement.
///
/// Layout: `<picked folder>/Holly Mixer/<mixer key>/manual-<id>.json`, the same names as on the device.
/// Only saved ("manual" and safety) backups travel; the automatic backup stays per device, because every
/// device must compare the mixer with *its own* last session.
/// A deleted backup leaves `<file>.deleted` behind so the other devices remove their copy instead of
/// uploading it again.
enum BackupSync {
    static let bookmarkKey = "backupSyncFolderBookmark"
    private static let folderName = "Holly Mixer"
    private static let tombstoneSuffix = ".deleted"

    struct Outcome: Equatable {
        /// Copies that arrived from the folder.
        var received = 0
        /// Copies sent to the folder.
        var sent = 0
        /// Copies removed because another device deleted them.
        var removed = 0
        /// Files iCloud has not downloaded yet; a later sync picks them up.
        var waiting = 0

        var changedLocal: Bool { received > 0 || removed > 0 }
    }

    // MARK: - The picked folder

    /// The folder saved earlier, and whether its bookmark needs to be saved again.
    static func savedFolder() -> (url: URL, isStale: Bool)? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }

    /// Remembers a folder returned by the document picker. Returns false when the bookmark can't be made.
    @discardableResult
    static func save(folder url: URL) -> Bool {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData() else { return false }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        return true
    }

    static func forgetFolder() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    // MARK: - Syncing

    /// Two-way merge of the manual backups in `local` and the shared folder. Blocking: call it off the main thread.
    nonisolated static func run(local: URL, folder: URL, key: String) -> Outcome {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }

        let manager = FileManager.default
        let remote = folder.appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
        var outcome = Outcome()
        do {
            try manager.createDirectory(at: local, withIntermediateDirectories: true)
            try manager.createDirectory(at: remote, withIntermediateDirectories: true)
        } catch {
            return outcome
        }

        // What the shared folder holds. A name that starts with "." and ends in ".icloud" is a file that
        // iCloud has not downloaded yet: ask for it and leave that name alone for now.
        var remoteFiles: Set<String> = []
        var deleted: Set<String> = []
        var notDownloaded: Set<String> = []
        for name in (try? manager.contentsOfDirectory(atPath: remote.path)) ?? [] {
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                let real = String(name.dropFirst().dropLast(".icloud".count))
                if isBackupName(real) || real.hasSuffix(tombstoneSuffix) {
                    notDownloaded.insert(real.replacingOccurrences(of: tombstoneSuffix, with: ""))
                    try? manager.startDownloadingUbiquitousItem(at: remote.appendingPathComponent(real))
                    outcome.waiting += 1
                }
            } else if name.hasSuffix(tombstoneSuffix) {
                deleted.insert(String(name.dropLast(tombstoneSuffix.count)))
            } else if isBackupName(name) {
                remoteFiles.insert(name)
            }
        }
        let localFiles = Set(((try? manager.contentsOfDirectory(atPath: local.path)) ?? []).filter(isBackupName))

        // 1. Deleted on another device: delete here too.
        for name in deleted {
            if localFiles.contains(name) {
                try? manager.removeItem(at: local.appendingPathComponent(name))
                outcome.removed += 1
            }
            if remoteFiles.contains(name) { coordinatedDelete(remote.appendingPathComponent(name)) }
        }

        // 2. New on the other side: copy over. A file is only copied if it really is a backup.
        for name in remoteFiles.subtracting(deleted).subtracting(localFiles) {
            guard let data = coordinatedRead(remote.appendingPathComponent(name)), isBackup(data) else { continue }
            if (try? data.write(to: local.appendingPathComponent(name), options: .atomic)) != nil { outcome.received += 1 }
        }
        for name in localFiles.subtracting(deleted).subtracting(remoteFiles).subtracting(notDownloaded) {
            guard let data = try? Data(contentsOf: local.appendingPathComponent(name)) else { continue }
            if coordinatedWrite(data, to: remote.appendingPathComponent(name)) { outcome.sent += 1 }
        }

        // 3. On both sides but different (a rename): the most recently changed one wins.
        for name in localFiles.intersection(remoteFiles).subtracting(deleted) {
            let localURL = local.appendingPathComponent(name)
            let remoteURL = remote.appendingPathComponent(name)
            guard let mine = try? Data(contentsOf: localURL),
                  let theirs = coordinatedRead(remoteURL), mine != theirs else { continue }
            if modificationDate(remoteURL) > modificationDate(localURL) {
                if isBackup(theirs), (try? theirs.write(to: localURL, options: .atomic)) != nil { outcome.received += 1 }
            } else if coordinatedWrite(mine, to: remoteURL) {
                outcome.sent += 1
            }
        }
        return outcome
    }

    /// Tells the other devices a backup was deleted. Blocking: call it off the main thread.
    nonisolated static func markDeleted(file name: String, folder: URL, key: String) {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let remote = folder.appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
        try? FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        coordinatedDelete(remote.appendingPathComponent(name))
        _ = coordinatedWrite(Data(), to: remote.appendingPathComponent(name + tombstoneSuffix))
    }

    // MARK: - Helpers

    nonisolated static func isBackupName(_ name: String) -> Bool {
        name.hasPrefix("manual-") && name.hasSuffix(".json")
    }

    private nonisolated static func isBackup(_ data: Data) -> Bool {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(MixerBackup.self, from: data)) != nil
    }

    private nonisolated static func modificationDate(_ url: URL) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
    }

    // Files in a cloud folder can be written by the sync daemon at any time: go through file coordination.

    private nonisolated static func coordinatedRead(_ url: URL) -> Data? {
        var result: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { readable in
            result = try? Data(contentsOf: readable)
        }
        return error == nil ? result : nil
    }

    private nonisolated static func coordinatedWrite(_ data: Data, to url: URL) -> Bool {
        var written = false
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { writable in
            written = (try? data.write(to: writable, options: .atomic)) != nil
        }
        return written && error == nil
    }

    private nonisolated static func coordinatedDelete(_ url: URL) {
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &error) { writable in
            try? FileManager.default.removeItem(at: writable)
        }
    }
}
