import SwiftUI

/// Save the live mixer state as a new scene, or rename / move an existing one.
@MainActor
struct SceneEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let store = SceneStore.shared
    /// Nil to save the current mixer state as a new scene.
    let sceneID: UUID?

    @State private var name = ""
    @State private var note = ""
    @State private var sectionID: UUID?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .frame(minHeight: 44)
                    TextField("Note, e.g. Pulpito only · band muted", text: $note)
                        .frame(minHeight: 44)
                } footer: {
                    if sceneID == nil {
                        Text("Captures every fader, mute, pan and send level, and the mute groups, as they are now.")
                    }
                }
                Section("Section") {
                    Picker("Section", selection: $sectionID) {
                        ForEach(store.show.sections) { section in
                            Text(LocalizedStringKey(section.title)).tag(Optional(section.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .navigationTitle(sceneID == nil ? L("Save current…") : L("Edit scene"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sceneID == nil ? L("Save") : L("Done")) { save() }
                        .disabled(trimmedName.isEmpty || sectionID == nil)
                }
            }
        }
        .onAppear(perform: populate)
        .presentationDetents([.large])
    }

    private func populate() {
        guard sectionID == nil else { return }
        if let sceneID, let scene = store.scene(sceneID) {
            name = scene.name
            note = scene.note
            sectionID = store.sectionID(of: sceneID)
        } else {
            name = "Scene \(store.allScenes.count + 1)"
            let current = store.show.currentSceneID.flatMap { store.sectionID(of: $0) }
            sectionID = current ?? store.show.sections.first?.id
        }
    }

    private func save() {
        guard let sectionID else { return }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sceneID {
            store.update(sceneID, name: trimmedName, note: trimmedNote, sectionID: sectionID)
        } else {
            store.addScene(name: trimmedName, note: trimmedNote, sectionID: sectionID)
        }
        dismiss()
    }
}

/// "Recall safe for this show": buses and strips a recall never changes.
@MainActor
struct SceneSafeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Mixer.self) private var mixer
    private let store = SceneStore.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(mixer.buses) { bus in
                        busToggle(bus)
                    }
                } header: {
                    Text("Buses")
                } footer: {
                    Text("Sends to these buses, and the bus fader and mute, never change on recall. Use it for musicians' in-ear mixes.")
                }
                Section("Skip these strips") {
                    ForEach(mixer.inputs + [mixer.main]) { strip in
                        stripToggle(strip)
                    }
                }
            }
            .navigationTitle("Recall safe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func busToggle(_ bus: Strip) -> some View {
        var number = 0
        if case .bus(let value) = bus.kind { number = value }
        let binding = Binding<Bool>(
            get: { store.show.safes.buses.contains(number) },
            set: { store.setBusSafe(number, $0) })
        return Toggle(isOn: binding) {
            HStack(spacing: 8) {
                Circle().fill(bus.color).frame(width: 8, height: 8)
                Text("Bus \(number) · \(bus.displayName)")
            }
        }
        .tint(Theme.accent)
        .frame(minHeight: 44)
    }

    private func stripToggle(_ strip: Strip) -> some View {
        let base = strip.base
        let binding = Binding<Bool>(
            get: { store.show.safes.strips.contains(base) },
            set: { store.setStripSafe(base, $0) })
        return Toggle(isOn: binding) {
            HStack(spacing: 8) {
                Circle().fill(strip.color).frame(width: 8, height: 8)
                Text(strip.displayName)
            }
        }
        .tint(Theme.accent)
        .frame(minHeight: 44)
    }
}

/// The actions available on a scene: preview, edit, reorder, update, delete.
@MainActor
struct SceneMenuItems: View {
    private let store = SceneStore.shared
    let scene: ShowScene
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button {
            store.selectedSceneID = scene.id
        } label: {
            Label("Preview recall", systemImage: "eye")
        }
        Button(action: onEdit) {
            Label("Rename or move…", systemImage: "pencil")
        }
        Button {
            store.moveScene(scene.id, by: -1)
        } label: {
            Label("Move earlier", systemImage: "arrow.left")
        }
        .disabled(!store.canMoveScene(scene.id, by: -1))
        Button {
            store.moveScene(scene.id, by: 1)
        } label: {
            Label("Move later", systemImage: "arrow.right")
        }
        .disabled(!store.canMoveScene(scene.id, by: 1))
        Button {
            store.overwriteWithCurrent(scene.id)
        } label: {
            Label("Replace with current mixer state", systemImage: "square.and.arrow.down")
        }
        Button(role: .destructive, action: onDelete) {
            Label("Delete", systemImage: "trash")
        }
    }
}

/// Every scene in order, with the same actions as the cards.
@MainActor
struct SceneListSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let store = SceneStore.shared
    @State private var editing: SceneSheetItem?
    @State private var deleting: ShowScene?

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.show.sections) { section in
                    if !section.scenes.isEmpty {
                        Section(section.title) {
                            ForEach(section.scenes) { scene in
                                row(scene)
                            }
                        }
                    }
                }
            }
            .overlay {
                if store.allScenes.isEmpty {
                    Text("No scenes yet.")
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .navigationTitle("All scenes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editing) { item in
                SceneEditSheet(sceneID: item.id)
            }
            .confirmationDialog("Delete this scene?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let deleting { store.deleteScene(deleting.id) }
                    deleting = nil
                }
            }
        }
    }

    private func row(_ scene: ShowScene) -> some View {
        Button {
            store.selectedSceneID = scene.id
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Text(store.number(of: scene.id))
                    .font(Theme.mono(13, .regular))
                    .foregroundStyle(Theme.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(scene.name).font(.system(size: 16, weight: .semibold))
                    if !scene.note.isEmpty {
                        Text(scene.note).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer()
                if scene.id == store.show.currentSceneID {
                    Text("LIVE NOW")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.greenText)
                }
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .contextMenu {
            SceneMenuItems(scene: scene, onEdit: { editing = SceneSheetItem(id: scene.id) }, onDelete: { deleting = scene })
        }
        .swipeActions {
            Button(role: .destructive) { deleting = scene } label: { Label("Delete", systemImage: "trash") }
            Button { editing = SceneSheetItem(id: scene.id) } label: { Label("Edit", systemImage: "pencil") }
                .tint(Theme.accent)
        }
    }
}

/// Identifies the scene being edited in a `sheet(item:)`.
struct SceneSheetItem: Identifiable {
    let id: UUID
}
