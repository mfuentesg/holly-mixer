import SwiftUI

/// Vertical fader. Grab the cap and drag: it moves relative to where the finger started
/// (no jumping to the touch). Double-tap anywhere on the fader returns it to 0 dB.
struct FaderView: View {
    let value: Float
    /// Tints the fader cap, e.g. with the colour of the bus whose sends are shown.
    var accent: Color? = nil
    var label = "Fader"
    var onTouchingChanged: (Bool) -> Void
    var onChange: (Float) -> Void

    static let unity: Float = 0.75
    private let capHeight: CGFloat = 40
    /// Extra touch area above and below the cap.
    private let grabMargin: CGFloat = 12

    @State private var dragStartValue: Float?

    var body: some View {
        GeometryReader { geometry in
            let travel = max(geometry.size.height - capHeight, 1)
            ZStack(alignment: .top) {
                Capsule()
                    .fill(Color(white: 0.22))
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)

                Rectangle()
                    .fill(Color(white: 0.55))
                    .frame(width: 22, height: 1)
                    .offset(y: capHeight / 2 + CGFloat(1 - Self.unity) * travel)

                // Only the cap (plus a margin) takes drags, so swiping elsewhere on the
                // strip still scrolls the mixer sideways.
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(colors: capColors, startPoint: .top, endPoint: .bottom))
                    .overlay(Rectangle().fill(.black).frame(height: 2))
                    .frame(width: min(geometry.size.width, 44), height: capHeight)
                    .shadow(radius: 2, y: 1)
                    .frame(width: geometry.size.width, height: capHeight + 2 * grabMargin)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { gesture in
                                if dragStartValue == nil {
                                    dragStartValue = value
                                    onTouchingChanged(true)
                                }
                                let delta = Float(-gesture.translation.height / travel)
                                onChange(min(max((dragStartValue ?? value) + delta, 0), 1))
                            }
                            .onEnded { _ in
                                dragStartValue = nil
                                onTouchingChanged(false)
                            }
                    )
                    .offset(y: CGFloat(1 - value) * travel - grabMargin)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                onTouchingChanged(true)
                onChange(Self.unity)
                onTouchingChanged(false)
            }
        }
        .frame(minHeight: 160)
        .sensoryFeedback(.selection, trigger: value >= Self.unity)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(formatDecibels(value) + " dB")
        .accessibilityAdjustableAction { direction in
            let step: Float = 0.02
            let next = direction == .increment ? value + step : value - step
            onChange(min(max(next, 0), 1))
        }
    }

    private var capColors: [Color] {
        if let accent {
            return [accent, accent.opacity(0.55)]
        }
        return [Color(white: 0.75), Color(white: 0.45)]
    }
}
