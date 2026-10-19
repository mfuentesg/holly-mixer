import SwiftUI

/// Simple full-screen page with a title and a Close button.
struct PlaceholderScreen: View {
    @Environment(Mixer.self) private var mixer
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            ScreenTopBar(title: title)
            Spacer()
            Text(message)
                .scaledFont(17)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .background(Theme.background.ignoresSafeArea())
    }
}

/// Top bar for full-screen pages: back to the mixer, title, optional trailing content.
private struct BackTitleKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// Label of the back button in `ScreenTopBar`; pages pushed from Settings say "Settings".
    var screenBackTitle: String? {
        get { self[BackTitleKey.self] }
        set { self[BackTitleKey.self] = newValue }
    }
}

struct ScreenTopBar<Trailing: View>: View {
    @Environment(Mixer.self) private var mixer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.screenBackTitle) private var backTitle
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 14) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .scaledFont(17, .bold)
                    Text(backTitle ?? L("Mixer"))
                        .scaledFont(15, .semibold)
                }
                .foregroundStyle(Theme.accentText)
                .padding(.leading, 6)
                .padding(.trailing, 12)
                .frame(height: 44)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .scaledFont(22, .bold)
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .scaledFont(12)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .lineLimit(1)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .frame(height: 72)
        .background(Theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }
}

extension ScreenTopBar where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = { EmptyView() }
    }
}
