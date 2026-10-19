import SwiftUI
import UniformTypeIdentifiers

/// Amber card shown over the mixer when the mixer's settings differ from the last saved ones
/// (usually after it was powered off and on).
struct BackupBanner: View {
    @Environment(Mixer.self) private var mixer
    private let store = BackupStore.shared

    var body: some View {
        if let pending = store.pending {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.meterAmber)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("The mixer's settings changed since your last session")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color(hex: 0xFFE4A0))
                        Text("\(pending.changes.count) values differ from the backup of \(pending.backup.date.mixit(date: .abbreviated, time: .shortened)). If the mixer was switched off and on, it may have lost them.")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: 0xE9D7A5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if store.isRestoring {
                    HStack(spacing: 10) {
                        ProgressView().tint(Theme.accentText)
                        Text("Restoring \(store.restoreProgress) of \(store.restoreTotal)")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.accentText)
                            .monospacedDigit()
                    }
                }
                if store.restoreWaitsForSilence {
                    HStack(spacing: 10) {
                        ProgressView().tint(Theme.accentText)
                        Text("Waiting for the sound system to go quiet before restoring")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accentText)
                        Spacer()
                        Button {
                            store.cancelCountdown()
                        } label: {
                            Text("Cancel")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.textBright)
                                .padding(.horizontal, 16)
                                .frame(height: 44)
                                .background(Theme.control, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let seconds = store.restoreCountdown {
                    HStack(spacing: 10) {
                        Text("Restoring your settings in \(seconds) s")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.accentText)
                            .monospacedDigit()
                        Spacer()
                        Button {
                            store.cancelCountdown()
                        } label: {
                            Text("Cancel")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.textBright)
                                .padding(.horizontal, 16)
                                .frame(height: 44)
                                .background(Theme.control, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        mixer.presentedScreen = .backups
                    } label: {
                        Text("Review and restore")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 16)
                            .frame(height: 44)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10))
                    }
                    Button {
                        store.keepMixerState()
                    } label: {
                        Text("Keep the mixer's")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textBright)
                            .padding(.horizontal, 16)
                            .frame(height: 44)
                            .background(Theme.control, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.borderStrong, lineWidth: 1))
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.meterAmber.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.meterAmber.opacity(0.45), lineWidth: 1))
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }
}

/// "Settings backup": the automatic and saved copies of the mixer's settings, with review and restore.
@MainActor
struct BackupView: View {
    @Environment(Mixer.self) private var mixer
    @Environment(\.horizontalSizeClass) private var sizeClass
    private let store = BackupStore.shared

    @State private var saving = false
    @State private var newName = ""
    @State private var reviewing: ReviewItem?
    @State private var renaming: MixerBackup?
    @State private var renameText = ""
    @State private var importing = false

    private struct ReviewItem: Identifiable {
        let id = UUID()
        let backup: MixerBackup
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenTopBar(title: sizeClass == .compact ? L("Backup") : L("Settings backup"), subtitle: subtitle) {
                Button {
                    newName = ""
                    saving = true
                } label: {
                    Text("Save now…")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(!mixer.fullStateReady && !mixer.isDemo)
            }
            ScrollView {
                VStack(spacing: 16) {
                    if let notice = store.notice {
                        Text(notice)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.greenText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Theme.meterGreen.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if let pending = store.pending { pendingCard(pending) }
                    autoCard
                    listCard
                }
                .padding(20)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.textPrimary)
        .onAppear { store.reload() }
        .alert("Save current settings", isPresented: $saving) {
            TextField("Name (e.g. Sunday good state)", text: $newName)
            Button("Save") { store.saveNow(name: newName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keeps every level, mute, name, EQ, gate and dynamics setting on this device.")
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let renaming { store.rename(renaming, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $reviewing) { item in
            BackupReviewSheet(backup: item.backup)
                .environment(mixer)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { store.importBackup(from: url) }
        }
    }

    private var subtitle: String {
        if let date = store.lastAutoSave {
            return L("Last automatic save \(date.mixit(date: .omitted, time: .shortened)) · \(mixer.mixerName.isEmpty ? L("mixer") : mixer.mixerName)")
        }
        return mixer.fullStateReady || mixer.isDemo ? "Nothing saved yet" : "Reading the mixer…"
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border, lineWidth: 1))
    }

    private func pendingCard(_ pending: PendingBackupDecision) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("THE MIXER LOOKS DIFFERENT").sectionLabelStyle(Theme.meterAmber)
            Text("\(pending.changes.count) values differ from the automatic backup of \(pending.backup.date.mixit(date: .abbreviated, time: .shortened)).")
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: 0xE9D7A5))
            HStack(spacing: 10) {
                Button {
                    reviewing = ReviewItem(backup: pending.backup)
                } label: {
                    Text("Review and restore")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10))
                }
                Button {
                    store.keepMixerState()
                } label: {
                    Text("Keep the mixer's")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .background(Theme.control, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.meterAmber.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.meterAmber.opacity(0.45), lineWidth: 1))
    }

    private var autoCard: some View {
        card {
            Toggle(isOn: Binding(get: { store.isAutoBackupOn }, set: { store.isAutoBackupOn = $0 })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Back up automatically")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Mixit saves the mixer's settings on this device a few seconds after every change. When you connect and the mixer has lost them, you can put them back.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minHeight: 44)
            Toggle(isOn: Binding(get: { store.isAutoRestoreOn }, set: { store.isAutoRestoreOn = $0 })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Restore automatically")
                        .font(.system(size: 17, weight: .semibold))
                    Text("If the mixer comes back reset, Mixit counts down 10 s and puts your last settings back. Cancel any time. It waits if the sound system is live.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minHeight: 44)
        }
    }

    private var listCard: some View {
        card {
            HStack {
                Text("SAVED SETTINGS").sectionLabelStyle()
                Spacer()
                Button {
                    importing = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accentText)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
            if store.backups.isEmpty {
                Text("Nothing saved yet. The first automatic backup is made right after the mixer has been read.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach(store.backups) { backup in
                row(backup)
            }
        }
    }

    private func row(_ backup: MixerBackup) -> some View {
        let compact = sizeClass == .compact
        let title = HStack(spacing: 12) {
            Image(systemName: backup.isAuto ? "clock.arrow.circlepath" : backup.isSafety == true ? "shield.lefthalf.filled" : "bookmark.fill")
                .font(.system(size: 16))
                .foregroundStyle(backup.isAuto ? Theme.textControl : Theme.accentText)
                .frame(width: 40, height: 40)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(backup.isAuto ? L("Automatic backup") : backup.name)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Text("\(backup.date.mixit(date: .abbreviated, time: .shortened)) · \(backup.values.count) values")
                    .font(Theme.mono(12, .regular))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(compact ? 2 : 1)
            }
        }
        let actions = HStack(spacing: 0) {
            if let url = store.exportURL(for: backup) {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textControl)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Share backup")
            }
            Menu {
                if !backup.isAuto {
                    Button("Rename") { renameText = backup.name; renaming = backup }
                }
                Button("Delete", role: .destructive) { store.delete(backup) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textControl)
                    .frame(width: 44, height: 44)
            }
            Button {
                reviewing = ReviewItem(backup: backup)
            } label: {
                Text("Review")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textBright)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .background(Theme.control, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.borderStrong, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!mixer.fullStateReady && !mixer.isDemo)
        }
        return Group {
            if compact {
                VStack(alignment: .leading, spacing: 6) {
                    title
                    HStack { Spacer(); actions }
                }
                .padding(.vertical, 8)
            } else {
                HStack(spacing: 12) {
                    title
                    Spacer()
                    actions
                }
                .frame(minHeight: 56)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1) }
    }
}

/// Shows what a restore would change on the mixer, grouped by channel, and restores it.
@MainActor
struct BackupReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Mixer.self) private var mixer
    private let store = BackupStore.shared

    let backup: MixerBackup
    @State private var changes: [BackupChange] = []
    @State private var includePhantom = false
    @State private var confirming = false

    private var phantomCount: Int { changes.filter(\.isPhantom).count }
    private var applyCount: Int { changes.count - (includePhantom ? 0 : phantomCount) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if changes.isEmpty {
                        Text("The mixer already matches this backup.")
                            .foregroundStyle(Theme.textTertiary)
                    }
                    ForEach(store.groups(for: changes)) { group in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 2).fill(group.color).frame(width: 4, height: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.title)
                                    .font(Theme.rounded(16))
                                Text(group.topics.joined(separator: ", "))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            Spacer()
                            Text("\(group.changes.count)")
                                .font(Theme.mono(14, .bold))
                                .foregroundStyle(Theme.textBright)
                        }
                        .frame(minHeight: 44)
                        .listRowBackground(Theme.card)
                    }
                } header: {
                    Text("\(applyCount) values will be written to the mixer").sectionLabelStyle()
                }
                if phantomCount > 0 {
                    Section {
                        Toggle("Also restore +48V phantom power (\(phantomCount))", isOn: $includePhantom)
                            .listRowBackground(Theme.card)
                    } footer: {
                        Text("Off by default: switching phantom power while the system is live can cause loud pops or damage ribbon mics.")
                    }
                }
                if store.isRestoring {
                    Section {
                        ProgressView(value: Double(store.restoreProgress), total: Double(max(store.restoreTotal, 1)))
                            .listRowBackground(Theme.card)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(backup.isAuto ? L("Automatic backup") : backup.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Restore") { confirming = true }
                        .disabled(applyCount == 0 || store.isRestoring)
                }
            }
            .confirmationDialog("Restore \(applyCount) values?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Restore to the mixer") {
                    Task {
                        await store.restore(changes, includePhantom: includePhantom)
                        dismiss()
                    }
                }
            } message: {
                Text("Faders, mutes and settings will jump to the saved values. Don't do this while the band is playing.")
            }
        }
        .onAppear { changes = store.changes(for: backup) }
    }
}
