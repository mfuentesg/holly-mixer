import SwiftUI

/// Channel / bus / main detail page (Channel.dc.html). Placeholder until implemented.
struct ChannelDetailView: View {
    @Environment(Mixer.self) private var mixer
    let strip: Strip

    var body: some View {
        PlaceholderScreen(title: strip.displayName, message: "Channel detail is coming soon.")
    }
}
