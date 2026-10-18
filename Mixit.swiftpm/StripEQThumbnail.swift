import SwiftUI

/// Small EQ curve shown on each channel strip. Placeholder: a flat line.
struct StripEQThumbnail: View {
    @Environment(Mixer.self) private var mixer
    let strip: Strip
    var width: CGFloat = 66

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(x: 0, y: size.height / 2, width: size.width, height: 1)),
                         with: .color(.white.opacity(0.08)))
        }
        .frame(width: width, height: 24)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }
}
