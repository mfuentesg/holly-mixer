import SwiftUI

/// Bottom banner that confirms what an undo just reverted, then fades after 3 seconds.
struct UndoToastView: View {
    @Environment(Mixer.self) private var mixer

    var body: some View {
        Group {
            if let toast = mixer.undoToast {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 14, weight: .bold))
                    Text(toast.text)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                }
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Theme.controlSelected, in: Capsule())
                .overlay(Capsule().stroke(Theme.borderStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(3))
                    if mixer.undoToast?.id == toast.id { mixer.undoToast = nil }
                }
                .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: mixer.undoToast)
        .padding(.bottom, 90)
        .allowsHitTesting(false)
    }
}
