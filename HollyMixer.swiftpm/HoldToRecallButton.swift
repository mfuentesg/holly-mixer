import SwiftUI

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
