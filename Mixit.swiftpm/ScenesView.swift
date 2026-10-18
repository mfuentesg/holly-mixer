import SwiftUI

/// Order of service and scene recall preview (Scenes.dc.html). Placeholder until implemented.
struct ScenesView: View {
    var body: some View {
        PlaceholderScreen(title: "Order of service", message: "Scenes are coming soon.")
    }
}

/// The scene control in the mixer header: previous / current scene / next.
struct HeaderSceneControl: View {
    @Environment(Mixer.self) private var mixer

    var body: some View {
        Button {
            mixer.presentedScreen = .scenes
        } label: {
            Text("Scenes")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 16)
                .frame(height: 48)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
