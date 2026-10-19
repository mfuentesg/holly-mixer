import SwiftUI

/// Order of service and scene recall preview (Scenes.dc.html).
@MainActor
struct ScenesView: View {
    @Environment(Mixer.self) private var mixer
    private let store = SceneStore.shared
    @State private var sheet: ScenesSheet?
    @State private var deleting: ShowScene?

    private enum ScenesSheet: Identifiable {
        case save, safe, all
        case edit(UUID)

        var id: String {
            switch self {
            case .save: return "save"
            case .safe: return "safe"
            case .all: return "all"
            case .edit(let id): return "edit-\(id)"
            }
        }
    }

    private enum CardState {
        case live, previewing, next, done, later
    }

    private var subtitle: String {
        let count = store.allScenes.count
        let scenes = count == 1 ? L("1 scene") : L("\(count) scenes")
        return L("\(scenes) · show file “\(store.show.name)” · last saved \(store.lastSavedText)")
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenTopBar(title: L("Order of service"), subtitle: subtitle) {
                topBarButtons
            }
            GeometryReader { proxy in
                layout(width: proxy.size.width)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.2), value: store.selectedSceneID)
        .onAppear { store.attach(mixer) }
        .onChange(of: mixer.mixerName) { _, _ in store.attach(mixer) }
        .onChange(of: mixer.isDemo) { _, _ in store.attach(mixer) }
        .sheet(item: $sheet) { sheet in
            sheetContent(sheet)
        }
        .confirmationDialog("Delete this scene?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let deleting { store.deleteScene(deleting.id) }
                deleting = nil
            }
        } message: {
            Text(deleting.map { L("“\($0.name)” will be removed from the show.") } ?? "")
        }
    }

    // MARK: Layout

    @ViewBuilder
    private func layout(width: CGFloat) -> some View {
        let wide = width >= 760
        if let scene = store.scene(store.selectedSceneID) {
            if wide {
                HStack(spacing: 0) {
                    pageContent(width: width - 500)
                        .opacity(0.55)
                    SceneRecallPreview(scene: scene)
                        .frame(width: 500)
                        .transition(.move(edge: .trailing))
                }
            } else {
                SceneRecallPreview(scene: scene)
            }
        } else {
            pageContent(width: width)
        }
    }

    private func pageContent(width: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                nowNext
                undoBanner
                if store.allScenes.isEmpty {
                    emptyState
                } else {
                    timeline(width: width - 48)
                }
                safeCard
            }
            .padding(24)
            .frame(width: width)
        }
    }

    // MARK: Top bar

    private var topBarButtons: some View {
        HStack(spacing: 10) {
            barButton(L("Recall safe…")) { sheet = .safe }
            barButton(L("All scenes")) { sheet = .all }
            barButton(L("Save current…"), primary: true) { sheet = .save }
        }
    }

    private func barButton(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: primary ? 15 : 14, weight: primary ? .bold : .semibold))
                .foregroundStyle(primary ? Theme.onAccent : Theme.textBright)
                .padding(.horizontal, primary ? 18 : 16)
                .frame(minHeight: 44)
                .background(primary ? Theme.accent : Theme.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    if !primary {
                        RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sheetContent(_ sheet: ScenesSheet) -> some View {
        switch sheet {
        case .save: SceneEditSheet(sceneID: nil)
        case .safe: SceneSafeSheet()
        case .all: SceneListSheet()
        case .edit(let id): SceneEditSheet(sceneID: id)
        }
    }

    // MARK: Now / next

    private var nowNext: some View {
        HStack(spacing: 12) {
            stepButton(-1)
            VStack(alignment: .leading, spacing: 2) {
                Text("NOW").sectionLabelStyle()
                Text(store.currentScene.map { store.label(of: $0) } ?? (store.allScenes.isEmpty ? L("No scenes yet") : L("No scene live")))
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text("NEXT").sectionLabelStyle()
                Text(store.nextScene.map { store.label(of: $0) } ?? "—")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.accentText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            stepButton(1)
        }
    }

    private func stepButton(_ delta: Int) -> some View {
        let enabled = store.stepTarget(delta) != nil
        let forward = delta > 0
        return Button {
            store.previewStep(delta)
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(forward ? Theme.onAccent : Theme.textBright)
                .frame(width: 56, height: 56)
                .background(forward ? Theme.accent : Theme.card, in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    if !forward {
                        RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(forward ? L("Next scene, preview before recall") : L("Previous scene, preview before recall"))
    }

    // MARK: Undo

    @ViewBuilder
    private var undoBanner: some View {
        if let undo = store.undoState {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.meterGreen)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.isFading ? L("Recalling \(undo.sceneLabel)…") : L("Recalled \(undo.sceneLabel)"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Undo is available for 10 minutes after any recall.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Button {
                    store.undoRecall()
                } label: {
                    Text("Undo recall")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textBright)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(Theme.control, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.borderStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border, lineWidth: 1))
        }
    }

    // MARK: Timeline

    private func timeline(width: CGFloat) -> some View {
        let count = max(store.show.sections.count, 1)
        let column = max(150, (width - 10 * CGFloat(count - 1)) / CGFloat(count))
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(store.show.sections) { section in
                    sectionColumn(section)
                        .frame(width: column, alignment: .leading)
                }
            }
        }
    }

    private func cardState(_ scene: ShowScene) -> CardState {
        let index = store.index(of: scene.id)
        let current = store.index(of: store.show.currentSceneID)
        let previewing = store.index(of: store.selectedSceneID)
        if let index, index == current { return .live }
        if let index, index == previewing { return .previewing }
        if previewing == nil, let index, index == store.index(of: store.nextScene?.id) { return .next }
        if let index, let current, index < current { return .done }
        return .later
    }

    private func sectionState(_ section: ShowSection) -> CardState {
        let states = section.scenes.map(cardState)
        if states.contains(.live) { return .live }
        if states.contains(.previewing) || states.contains(.next) { return .next }
        if !states.isEmpty && states.allSatisfy({ $0 == .done }) { return .done }
        return .later
    }

    private func sectionColumn(_ section: ShowSection) -> some View {
        let state = sectionState(section)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                sectionDot(state)
                SceneDashLine(dashed: state == .next || state == .later)
                    .frame(height: 2)
            }
            .frame(height: 16)
            Text(LocalizedStringKey(section.title))
                .font(.system(size: 13, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(titleColor(state))
            if section.scenes.isEmpty {
                Text("No scenes")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim)
            }
            ForEach(section.scenes) { scene in
                card(scene, state: cardState(scene))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func titleColor(_ state: CardState) -> Color {
        switch state {
        case .live: return Theme.textPrimary
        case .next, .previewing: return Theme.accentText
        default: return Theme.textTertiary
        }
    }

    @ViewBuilder
    private func sectionDot(_ state: CardState) -> some View {
        switch state {
        case .live:
            Circle().fill(Theme.meterGreen).frame(width: 12, height: 12)
                .overlay(Circle().stroke(Theme.meterGreen.opacity(0.25), lineWidth: 4))
        case .next, .previewing:
            Circle().fill(Theme.accent).frame(width: 12, height: 12)
        case .done:
            Circle().fill(Theme.textDim).frame(width: 12, height: 12)
        case .later:
            Circle().fill(Theme.background).frame(width: 12, height: 12)
                .overlay(Circle().stroke(Theme.textDim, lineWidth: 2))
        }
    }

    // MARK: Cards

    private func card(_ scene: ShowScene, state: CardState) -> some View {
        let number = store.number(of: scene.id)
        let tag = cardTag(scene, state)
        return Button {
            store.selectedSceneID = scene.id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(number)
                        .font(Theme.mono(12, .regular))
                        .foregroundStyle(Theme.textTertiary)
                    Text(scene.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                if !scene.note.isEmpty {
                    Text(scene.note)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
                Text(tag)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(tagColor(state))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .frame(minHeight: 44)
            .background(cardFill(state), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(cardBorder(state), lineWidth: borderWidth(state)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .contextMenu {
            SceneMenuItems(scene: scene, onEdit: { sheet = .edit(scene.id) }, onDelete: { deleting = scene })
        }
        .accessibilityLabel("Scene \(number), \(scene.name). \(scene.note). \(tag.capitalized)")
        .accessibilityHint("Opens the recall preview")
    }

    private func cardTag(_ scene: ShowScene, _ state: CardState) -> String {
        switch state {
        case .live: return L("LIVE NOW")
        case .previewing:
            return store.index(of: scene.id) == store.index(of: store.nextScene?.id) ? L("NEXT · PREVIEWING") : L("PREVIEWING")
        case .next: return L("NEXT")
        case .done: return L("DONE")
        case .later: return L("UP NEXT")
        }
    }

    private func tagColor(_ state: CardState) -> Color {
        switch state {
        case .live: return Theme.greenText
        case .previewing, .next: return Theme.accentText
        default: return Theme.textMuted
        }
    }

    private func cardFill(_ state: CardState) -> Color {
        switch state {
        case .live: return Theme.meterGreen.opacity(0.10)
        case .previewing: return Theme.accent.opacity(0.10)
        default: return Theme.surface
        }
    }

    private func cardBorder(_ state: CardState) -> Color {
        switch state {
        case .live: return Theme.meterGreen.opacity(0.6)
        case .previewing: return Theme.accent
        default: return Theme.border
        }
    }

    private func borderWidth(_ state: CardState) -> CGFloat {
        state == .live || state == .previewing ? 1.5 : 1
    }

    // MARK: Empty state and safes

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 36))
                .foregroundStyle(Theme.textMuted)
            Text("No scenes yet")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text("Set the mixer up for a part of the service, then save it as a scene. Mixit can preview and recall it later.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button {
                sheet = .save
            } label: {
                Text("Save current…")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 22)
                    .frame(minHeight: 48)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border, lineWidth: 1))
    }

    private var safeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RECALL SAFE FOR THIS SHOW").sectionLabelStyle()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8, alignment: .leading)],
                      alignment: .leading, spacing: 8) {
                ForEach(mixer.buses.filter { isSafeBus($0) }) { bus in
                    chip(bus.displayName, dot: bus.color, prefix: L("Bus \(busNumber(bus)) · "))
                }
                ForEach((mixer.inputs + [mixer.main]).filter { store.show.safes.strips.contains($0.base) }) { strip in
                    chip(strip.displayName, dot: strip.color, prefix: L("Skip · "))
                }
                chip(L("Preamp gain & +48V (all)"))
                chip(L("Routing"))
            }
            Text("Musicians' in-ear mixes and phantom power never change on recall.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border, lineWidth: 1))
    }

    private func busNumber(_ bus: Strip) -> Int {
        if case .bus(let number) = bus.kind { return number }
        return 0
    }

    private func isSafeBus(_ bus: Strip) -> Bool {
        store.show.safes.buses.contains(busNumber(bus))
    }

    private func chip(_ title: String, dot: Color? = nil, prefix: String = "") -> some View {
        HStack(spacing: 8) {
            if let dot {
                Circle().fill(dot).frame(width: 8, height: 8)
            }
            Text(prefix + title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

/// The line next to a timeline dot: solid for sections that are done or live, dashed for the rest.
struct SceneDashLine: View {
    let dashed: Bool

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: 0, y: proxy.size.height / 2))
                path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height / 2))
            }
            .stroke(dashed ? Color(hex: 0x3A3E45) : Theme.textDim,
                    style: StrokeStyle(lineWidth: 2, dash: dashed ? [6, 4] : []))
        }
    }
}

/// The scene control in the mixer header: previous / current scene / next.
/// The arrows open the page with a recall preview; they never recall by themselves.
@MainActor
struct HeaderSceneControl: View {
    @Environment(Mixer.self) private var mixer
    private let store = SceneStore.shared

    var body: some View {
        HStack(spacing: 0) {
            arrow("chevron.left", delta: -1, label: L("Previous scene, preview before recall"))
            labelButton
            arrow("chevron.right", delta: 1, label: L("Next scene, preview before recall"))
        }
        .padding(.horizontal, 2)
        .frame(height: 48)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
        .onAppear { store.attach(mixer) }
        .onChange(of: mixer.mixerName) { _, _ in store.attach(mixer) }
        .onChange(of: mixer.isDemo) { _, _ in store.attach(mixer) }
    }

    private var isEmpty: Bool { store.allScenes.isEmpty }

    private var topLine: String {
        guard let current = store.currentScene else { return L("NO SCENE LIVE") }
        let number = store.number(of: current.id)
        guard let next = store.nextScene else { return L("SCENE \(number) · LAST") }
        return L("SCENE \(number) · NEXT: \(next.name.uppercased())")
    }

    private var labelButton: some View {
        Button {
            mixer.presentedScreen = .scenes
        } label: {
            Group {
                if isEmpty {
                    Text("Scenes")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                } else {
                    VStack(spacing: 1) {
                        Text(topLine)
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(store.currentScene?.name ?? "—")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: 150, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isEmpty ? L("Scenes") : "\(topLine.capitalized), \(store.currentScene?.name ?? "none")")
        .accessibilityHint("Opens the order of service")
    }

    private func arrow(_ symbol: String, delta: Int, label: String) -> some View {
        let enabled = isEmpty || store.stepTarget(delta) != nil
        return Button {
            store.previewStep(delta)
            mixer.presentedScreen = .scenes
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.textControl)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}
