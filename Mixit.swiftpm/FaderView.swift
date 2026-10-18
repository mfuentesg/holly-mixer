import SwiftUI

/// Vertical fader with a dB scale. Grab the cap and drag: it moves relative to where the finger
/// started (no jumping to the touch). Double-tap anywhere on the fader returns it to 0 dB.
struct FaderView: View {
    let value: Float
    /// Colour of the level fill and the cap's centre line (channel or bus colour).
    var tint: Color = .white
    /// Dims the fill, e.g. when the strip is muted.
    var isDimmed = false
    var label = "Fader"
    var onTouchingChanged: (Bool) -> Void
    var onChange: (Float) -> Void

    static let unity: Float = 0.75
    private let capHeight: CGFloat = 44
    /// Extra touch area above and below the cap.
    private let grabMargin: CGFloat = 12

    /// Scale marks in dB; `nil` is -∞.
    private static let marks: [Float?] = [10, 5, 0, -5, -10, -20, -30, -40, -50, nil]

    @State private var dragStartValue: Float?

    var body: some View {
        GeometryReader { geometry in
            let travel = max(geometry.size.height - capHeight, 1)
            let isDragging = dragStartValue != nil

            ZStack(alignment: .top) {
                scale(travel: travel)

                // Only the cap (plus a margin) takes drags, so swiping elsewhere on the
                // strip still scrolls the mixer sideways.
                cap(width: min(geometry.size.width - 8, 46))
                    .scaleEffect(isDragging ? 1.06 : 1)
                    .animation(.spring(duration: 0.2), value: isDragging)
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

    /// Track, level fill, tick marks and dB labels.
    private func scale(travel: CGFloat) -> some View {
        Canvas { context, size in
            let midX = size.width / 2 + 6
            let top = capHeight / 2
            func y(_ position: Float) -> CGFloat { top + CGFloat(1 - position) * travel }

            for mark in Self.marks {
                let position = mark.map(decibelsToFader) ?? 0
                let markY = y(position)
                let isUnity = mark == 0
                let width: CGFloat = isUnity ? 24 : 14
                context.fill(
                    Path(CGRect(x: midX - width / 2, y: markY - 0.5, width: width, height: 1)),
                    with: .color(.white.opacity(isUnity ? 0.45 : 0.16))
                )
                let text = mark.map { String(Int(abs($0))) } ?? "∞"
                context.draw(
                    Text(text)
                        .font(.system(size: 8, weight: isUnity ? .bold : .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(isUnity ? 0.6 : 0.3)),
                    at: CGPoint(x: 7, y: markY),
                    anchor: .center
                )
            }

            let track = CGRect(x: midX - 2, y: top, width: 4, height: travel)
            context.fill(Path(roundedRect: track, cornerRadius: 2), with: .color(Theme.track))

            let fillTop = y(value)
            let fill = CGRect(x: midX - 2, y: fillTop, width: 4, height: top + travel - fillTop)
            context.fill(
                Path(roundedRect: fill, cornerRadius: 2),
                with: .color(tint.opacity(isDimmed ? 0.3 : 0.85))
            )
        }
    }

    private func cap(width: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(LinearGradient(colors: [Color(white: 0.88), Color(white: 0.6)],
                                     startPoint: .top, endPoint: .bottom))
            VStack(spacing: 4) {
                grip
                grip
                Capsule()
                    .fill(tint)
                    .frame(height: 3)
                    .padding(.horizontal, 5)
                grip
                grip
            }
        }
        .frame(width: width, height: capHeight)
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.6), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.55), radius: 5, y: 3)
        .offset(x: 6)
    }

    private var grip: some View {
        Rectangle()
            .fill(.black.opacity(0.14))
            .frame(height: 1)
            .padding(.horizontal, 9)
    }
}

/// Inverse of `faderToDecibels`: dB to fader position 0...1.
func decibelsToFader(_ db: Float) -> Float {
    switch db {
    case -10...: return min((db + 30) / 40, 1)
    case -30 ..< -10: return (db + 50) / 80
    case -60 ..< -30: return (db + 70) / 160
    default: return max((db + 90) / 480, 0)
    }
}
