import SwiftUI

/// The mixer's own 64 snapshot slots: see their names, load one, or save the current state into one.
/// Before a load Holly Mixer keeps a safety copy of the current settings, so it can be undone from Settings backup.
@MainActor
struct SnapshotsView: View {
    @Environment(Mixer.self) private var mixer
    private let backups = BackupStore.shared

    @State private var loading: Int?
    @State private var saving: Int?
    @State private var deleting: Int?
    @State private var saveName = ""

    var body: some View {
        VStack(spacing: 0) {
            ScreenTopBar(title: L("Mixer snapshots"), subtitle: L("The 64 slots stored inside the mixer")) {
                Button {
                    mixer.requestSnapshotNames()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .scaledFont(14, .semibold)
                        .foregroundStyle(Theme.textBright)
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(Theme.control, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            List {
                Section {
                    ForEach(1...64, id: \.self) { slot in
                        row(slot)
                            .listRowBackground(Theme.card)
                    }
                } footer: {
                    Text("Loading a snapshot changes whatever its recall scope covers, like on the mixer itself. Holly Mixer saves a safety copy first. The commands follow the official protocol document and still need to be checked on a real mixer.")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .background(Theme.background.ignoresSafeArea())
        .textPageTypeSize()
        .foregroundStyle(Theme.textPrimary)
        .onAppear { mixer.requestSnapshotNames() }
        .confirmationDialog(loading.map { L("Load snapshot \($0)?") } ?? "", isPresented: Binding(
            get: { loading != nil }, set: { if !$0 { loading = nil } }), titleVisibility: .visible) {
            Button("Load snapshot") {
                if let slot = loading {
                    backups.saveSafety(reason: L("snapshot \(slot)"))
                    mixer.loadSnapshot(slot)
                }
                loading = nil
            }
        } message: {
            Text("Faders, mutes and settings can jump. Don't do this while the band is playing.")
        }
        .confirmationDialog(deleting.map { L("Delete snapshot \($0)?") } ?? "", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let slot = deleting {
                    backups.saveSafety(reason: L("deleting snapshot \(slot)"))
                    mixer.deleteSnapshot(slot)
                }
                deleting = nil
            }
        } message: {
            Text("The slot becomes empty on the mixer.")
        }
        .alert(saving.map { L("Save into slot \($0)") } ?? "", isPresented: Binding(
            get: { saving != nil }, set: { if !$0 { saving = nil } })) {
            TextField("Name (31 characters at most)", text: $saveName)
                .onChange(of: saveName) { _, text in
                    if text.count > 31 { saveName = String(text.prefix(31)) }
                }
            Button("Save") {
                if let slot = saving { mixer.saveSnapshot(slot, name: saveName) }
                saving = nil
            }
            Button("Cancel", role: .cancel) { saving = nil }
        } message: {
            Text("This replaces what the slot holds now.")
        }
    }

    private func row(_ slot: Int) -> some View {
        let name = mixer.snapshotNames[slot - 1]
        // The XR18 keeps reporting a deleted slot as the last one used; an empty slot is never "last used".
        let isCurrent = mixer.currentSnapshot == slot && !name.isEmpty
        return HStack(spacing: 12) {
            Text(String(format: "%02d", slot))
                .font(Theme.mono(13, .bold))
                .foregroundStyle(isCurrent ? Theme.accentText : Theme.textTertiary)
                .frame(width: 30, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(name.isEmpty ? L("Empty") : name)
                    .scaledFont(16, .semibold)
                    .foregroundStyle(name.isEmpty ? Theme.textMuted : Theme.textPrimary)
                    .lineLimit(1)
                if isCurrent {
                    Text("LAST USED").sectionLabelStyle(Theme.accentText)
                }
            }
            Spacer()
            if !name.isEmpty {
                Button {
                    deleting = slot
                } label: {
                    Image(systemName: "trash")
                        .scaledFont(14)
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete snapshot \(slot)")
            }
            Button {
                saveName = name
                saving = slot
            } label: {
                Text("Save here")
                    .scaledFont(13, .semibold)
                    .foregroundStyle(Theme.textControl)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
            }
            .buttonStyle(.plain)
            Button {
                loading = slot
            } label: {
                Text("Load")
                    .scaledFont(14, .bold)
                    .foregroundStyle(name.isEmpty ? Theme.textMuted : Theme.onAccent)
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .background(name.isEmpty ? Theme.control : Theme.accent, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(name.isEmpty)
        }
        .frame(minHeight: 52)
    }
}
