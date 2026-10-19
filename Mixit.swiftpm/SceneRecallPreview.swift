import SwiftUI

/// The 500 pt "Recall preview" panel: what a recall would change, with press-and-hold to confirm.
@MainActor
struct SceneRecallPreview: View {
    private let store = SceneStore.shared
    let scene: ShowScene

    var body: some View {
        let diff = store.diff(to: scene.snapshot)
        VStack(spacing: 0) {
            header(diff)
            SceneWarningsView(changes: diff.changes)
            changeList(diff)
            footer
        }
        .frame(maxHeight: .infinity)
        .background(Theme.strip)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.borderStrong).frame(width: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 24, x: -12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recall preview")
    }

    // MARK: Header

    private func header(_ diff: SceneDiff) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RECALL PREVIEW")
                .sectionLabelStyle(Theme.accentText)
            Text("Go to \(store.label(of: scene))?")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            summary(diff)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    private func summary(_ diff: SceneDiff) -> some View {
        let origin = store.currentScene.map { "From \(store.label(of: $0))" } ?? "From the current mixer state"
        return (Text("\(origin) · ")
            + Text("\(diff.changes.count)").font(Theme.mono(14)).foregroundColor(Theme.textBright)
            + Text(diff.changes.count == 1 ? L(" change") : L(" changes"))
            + Text(" · \(diff.keptSafe) kept safe"))
            .font(.system(size: 14))
            .foregroundStyle(Theme.textSecondary)
    }

    // MARK: Changes

    private func changeList(_ diff: SceneDiff) -> some View {
        ScrollView {
            if diff.changes.isEmpty {
                Text("The mixer already matches this scene.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 24)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(SceneChangeGroup.allCases) { group in
                        groupSection(group, diff.changes(in: group))
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func groupSection(_ group: SceneChangeGroup, _ changes: [SceneChange]) -> some View {
        if !changes.isEmpty {
            HStack(spacing: 8) {
                Text(group.title).sectionLabelStyle()
                Text("\(changes.count)")
                    .font(Theme.mono(11, .regular))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.top, 14)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
            ForEach(changes) { change in
                SceneChangeRow(change: change)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        @Bindable var bindable = store
        return VStack(spacing: 12) {
            Toggle(isOn: $bindable.fadeFaders) {
                Text("Fade faders over 2 s")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textPrimary)
            }
            .tint(Theme.accent)
            .frame(minHeight: 44)
            HStack(spacing: 10) {
                Button {
                    store.selectedSceneID = nil
                } label: {
                    Text("Cancel")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textBright)
                        .padding(.horizontal, 22)
                        .frame(height: 56)
                        .background(Theme.control, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.borderStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
                HoldToRecallButton(label: L("Recall scene \(store.label(of: scene))")) {
                    store.recall(scene.id, fade: store.fadeFaders)
                }
            }
            Text("Undo is available for 10 minutes after any recall.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 22)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }
}

/// One "name  from → to" row in the preview.
@MainActor
struct SceneChangeRow: View {
    let change: SceneChange

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(change.color)
                .frame(width: 4, height: 20)
            Text(change.name)
                .font(Theme.rounded(15))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(change.from)
                .font(Theme.mono(13, .regular))
                .foregroundStyle(Theme.textTertiary)
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
            Text(change.to)
                .font(Theme.mono(13, .bold))
                .foregroundStyle(change.tone.color)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .frame(height: 40)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(change.name), \(change.from) to \(change.to)")
    }
}

/// Amber boxes for channels with signal that the recall would silence.
@MainActor
struct SceneWarningsView: View {
    private let store = SceneStore.shared
    let changes: [SceneChange]

    var body: some View {
        let warnings = store.warnings(for: changes)
        if !warnings.isEmpty {
            VStack(spacing: 8) {
                ForEach(warnings.prefix(3)) { warning in
                    warningBox(warning)
                }
                if warnings.count > 3 {
                    Text("and \(warnings.count - 3) more channels with signal")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.amberText)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
        }
    }

    private func warningBox(_ warning: SceneWarning) -> some View {
        let level = String(format: "%.0f", abs(warning.level))
        let text = Text("\(warning.name) is live right now").fontWeight(.bold).foregroundColor(Color(hex: 0xFFE4A0))
            + Text(" (−\(level) dBFS). This recall \(warning.action). Wait for the song to end, or fade over 2 s.")
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.meterAmber)
                .padding(.top, 1)
            text
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: 0xF5DFA0))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.meterAmber.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.meterAmber.opacity(0.45), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Warning. \(warning.name) is live right now at minus \(level) dBFS. This recall \(warning.action).")
    }
}

/// A button that recalls only after being held for about 0.6 s, so a stray tap cannot change the mix.
/// VoiceOver users activate it with a double tap.
@MainActor
struct HoldToRecallButton: View {
    let label: String
    /// Idle caption; the default is "Hold to recall".
    var title = "Hold to recall"
    var height: CGFloat = 56
    var cornerRadius: CGFloat = 12
    let onComplete: () -> Void

    @State private var progress: Double = 0
    @State private var isHolding = false
    @State private var holdTask: Task<Void, Never>?
    @State private var completions = 0

    private static let holdDuration: TimeInterval = 0.6

    var body: some View {
        ZStack(alignment: .leading) {
            Color(hex: 0x3A2410)
            GeometryReader { proxy in
                Theme.accent.frame(width: proxy.size.width * progress)
            }
            HStack(spacing: 10) {
                Text(isHolding ? L("Keep holding") : title)
                    .font(.system(size: 16, weight: .bold))
                Text(String(format: "%.1f s", max(0, Self.holdDuration * (1 - progress))))
                    .font(Theme.mono(13, .regular))
                    .opacity(0.85)
            }
            .foregroundStyle(progress > 0.5 ? Theme.onAccent : Color.white)
            .frame(maxWidth: .infinity)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in begin() }
                .onEnded { _ in cancel() }
        )
        .sensoryFeedback(.success, trigger: completions)
        .onDisappear { cancel() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Press and hold to \(label)")
        .accessibilityHint("Double tap to recall")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            completions += 1
            onComplete()
        }
    }

    private func begin() {
        guard !isHolding else { return }
        isHolding = true
        holdTask = Task { @MainActor in
            let start = Date()
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(start)
                progress = min(elapsed / Self.holdDuration, 1)
                if elapsed >= Self.holdDuration {
                    finish()
                    return
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func finish() {
        isHolding = false
        holdTask = nil
        progress = 0
        completions += 1
        onComplete()
    }

    private func cancel() {
        holdTask?.cancel()
        holdTask = nil
        isHolding = false
        withAnimation(.easeOut(duration: 0.15)) { progress = 0 }
    }
}
