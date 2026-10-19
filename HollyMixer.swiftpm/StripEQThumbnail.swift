import SwiftUI

/// Small EQ curve shown on each channel strip, drawn from the strip's real EQ parameters.
struct StripEQThumbnail: View {
    @Environment(Mixer.self) private var mixer
    let strip: Strip
    var width: CGFloat = 66

    /// Vertical scale: points per dB, and the largest excursion drawn.
    private let pointsPerDecibel = 1.2
    private let limit = 10.0

    var body: some View {
        let curve = EQModel.thumbnailCurve(mixer, strip, count: max(Int(width / 1.5), 8))
        let stroke = strokeColor
        let scale = pointsPerDecibel
        let clamp = limit
        Canvas { context, size in
            let middle = size.height / 2
            context.fill(Path(CGRect(x: 0, y: middle - 0.5, width: size.width, height: 1)),
                         with: .color(.white.opacity(0.08)))
            var path = Path()
            if curve.isEmpty {
                path.move(to: CGPoint(x: 0, y: middle))
                path.addLine(to: CGPoint(x: size.width, y: middle))
            } else {
                let last = Double(curve.count - 1)
                for (index, decibels) in curve.enumerated() {
                    let x = size.width * CGFloat(Double(index) / last)
                    let y = middle - CGFloat(min(max(decibels, -clamp / scale), clamp / scale) * scale)
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            context.stroke(path, with: .color(stroke), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .frame(width: width, height: 24)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
        .task(id: strip.id) {
            mixer.request(XR18Params.thumbnailAddresses(for: strip))
        }
    }

    private var strokeColor: Color {
        if !strip.isNamed { return Color(hex: 0x4A4F58) }
        if !strip.isOn { return Color(hex: 0x5A5F69) }
        return Color(hex: 0xB9BDC5)
    }
}
