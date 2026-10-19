import SwiftUI

/// Vertical fader with a dB scale on its left. Grab the cap and drag: it moves relative to
/// where the finger started (no jumping to the touch). Double-tap the cap returns it to 0 dB (not from far below).
struct FaderView: View {
    let value: Float
    /// Colour of the level line (channel colour, or the bus colour in sends mode).
    var lineColor: Color = Theme.textControl
    /// Colour of the line across the middle of the cap.
    var capLineColor: Color = Theme.textControl
    var isMuted = false
    var capWidth: CGFloat = 38
    var label = "Fader"
    /// Shorter cap and travel margins for landscape iPhones.
    var isCompact = false
    @Binding var isDragging: Bool
    var onTouchingChanged: (Bool) -> Void
    var onChange: (Float) -> Void

    static let unity: Float = 0.75
    private var capHeight: CGFloat { isCompact ? 40 : 54 }
    /// Space above and below the travel so the cap can sit at the ends.
    private var inset: CGFloat { isCompact ? 20 : 28 }
    private let tickColumn: CGFloat = 14

    /// Scale marks in dB; `nil` is -∞.
    private static let marks: [(db: Float?, label: String)] = [
        (10, "10"), (5, "5"), (0, "0"), (-5, "5"), (-10, "10"), (-20, "20"),
        (-30, "30"), (-40, "40"), (-50, "50"), (nil, "∞"),
    ]

    @State private var dragStartValue: Float?
    @State private var dragStartHeight: CGFloat = 0
    @State private var isHorizontalSwipe = false

    var body: some View {
        GeometryReader { geometry in
            let travel = max(geometry.size.height - inset * 2, 1)
            let trackWidth = geometry.size.width - tickColumn - 3
            let centerX = tickColumn + 3 + trackWidth / 2
            let capCenterY = inset + CGFloat(1 - value) * travel

            ZStack(alignment: .topLeading) {
                scale(travel: travel, centerX: centerX, trackWidth: trackWidth)

                if isDragging {
                    Text(formatDecibels(value))
                        .font(Theme.mono(12, .bold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
                        .shadow(color: .black.opacity(0.5), radius: 8, y: 6)
                        .fixedSize()
                        .position(x: centerX, y: capCenterY - 38 - 13)
                        .zIndex(2)
                }

                // Only the cap takes drags, so swiping elsewhere scrolls the strip row.
                cap
                    .frame(width: max(trackWidth, capWidth), height: capHeight + 16)
                    .contentShape(Rectangle())
                    .gesture(drag(travel: travel))
                    // Reset to 0 dB only from the cap, and never from far below it: a stray double tap must
                    // not turn a quiet channel into a +30 dB jump.
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        guard value >= decibelsToFader(-20) else { return }
                        onTouchingChanged(true)
                        onChange(Self.unity)
                        onTouchingChanged(false)
                    })
                    .position(x: centerX, y: capCenterY)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(minHeight: isCompact ? 70 : 140)
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

    private func drag(travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if dragStartValue == nil && !isHorizontalSwipe {
                    // Wait for a clear vertical move: a sideways swipe across the strips only scrolls.
                    let size = gesture.translation
                    guard max(abs(size.width), abs(size.height)) >= 6 else { return }
                    if abs(size.width) > abs(size.height) {
                        isHorizontalSwipe = true
                        return
                    }
                    dragStartValue = value
                    dragStartHeight = size.height
                    isDragging = true
                    onTouchingChanged(true)
                }
                guard let start = dragStartValue else { return }
                let delta = Float(-(gesture.translation.height - dragStartHeight) / travel)
                onChange(min(max(start + delta, 0), 1))
            }
            .onEnded { _ in
                isHorizontalSwipe = false
                guard dragStartValue != nil else { return }
                dragStartValue = nil
                isDragging = false
                onTouchingChanged(false)
            }
    }

    /// Tick labels, the recessed track, the unity line and the level line.
    private func scale(travel: CGFloat, centerX: CGFloat, trackWidth: CGFloat) -> some View {
        Canvas { context, size in
            func y(_ position: Float) -> CGFloat { inset + CGFloat(1 - position) * travel }

            for mark in Self.marks {
                let isUnity = mark.db == 0
                context.draw(
                    Text(mark.label)
                        .font(Theme.mono(9, isUnity ? .bold : .regular))
                        .foregroundStyle(isUnity ? Theme.textBright : Theme.textMuted),
                    at: CGPoint(x: tickColumn, y: y(mark.db.map(decibelsToFader) ?? 0)),
                    anchor: .trailing
                )
            }

            let track = CGRect(x: centerX - 2.5, y: inset - 4, width: 5, height: travel + 8)
            context.fill(Path(roundedRect: track, cornerRadius: 3), with: .color(Theme.well))
            context.stroke(Path(roundedRect: track.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3),
                           with: .color(.white.opacity(0.06)), lineWidth: 1)

            let unityY = y(Self.unity)
            context.fill(Path(CGRect(x: tickColumn + 6, y: unityY - 0.5, width: trackWidth - 6, height: 1)),
                         with: .color(.white.opacity(0.22)))

            let top = y(value)
            let line = CGRect(x: centerX - 1.5, y: top, width: 3, height: inset + travel - top)
            context.fill(Path(roundedRect: line, cornerRadius: 1.5),
                         with: .color(lineColor.opacity(isMuted ? 0.3 : 0.9)))
        }
    }

    private var cap: some View {
        VStack(spacing: 4) {
            grip
            grip
            RoundedRectangle(cornerRadius: 1)
                .fill(capLineColor)
                .frame(width: capWidth - 10, height: 2)
            grip
            grip
        }
        .frame(width: capWidth, height: capHeight)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(
                    colors: isDragging ? [Color(hex: 0x555A63), Color(hex: 0x30333A)]
                                       : [Color(hex: 0x464A52), Color(hex: 0x2B2E34)],
                    startPoint: .top, endPoint: .bottom))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isDragging ? Theme.accent : Color.white.opacity(0.16), lineWidth: 1)
        }
        .background {
            if isDragging {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.accent.opacity(0.28), lineWidth: 3)
                    .padding(-2.5)
            }
        }
        .shadow(color: .black.opacity(isDragging ? 0.7 : 0.55), radius: isDragging ? 13 : 7, y: isDragging ? 14 : 6)
        .scaleEffect(isDragging ? 1.08 : 1)
        .opacity(isMuted ? 0.55 : 1)
        .animation(.spring(duration: 0.18), value: isDragging)
    }

    private var grip: some View {
        Rectangle()
            .fill(Color.white.opacity(0.24))
            .frame(width: capWidth - 16, height: 1)
    }
}

/// LED-style meter: green to -18 dB, amber to -6 dB, red above, with a peak-hold line.
struct MeterView: View {
    /// Level in dBFS; the meter shows -60...0.
    let level: Float
    var peak: Float?

    var body: some View {
        Canvas { context, size in
            let height = size.height
            func fraction(_ db: Float) -> CGFloat { CGFloat(min(max((db + 60) / 60, 0), 1)) }

            // Zones: green 0-70 %, amber 70-90 %, red 90-100 % of the height.
            context.fill(Path(CGRect(x: 0, y: height * 0.3, width: size.width, height: height * 0.7)),
                         with: .color(Theme.meterGreen))
            context.fill(Path(CGRect(x: 0, y: height * 0.1, width: size.width, height: height * 0.2)),
                         with: .color(Theme.meterAmber))
            context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: height * 0.1)),
                         with: .color(Theme.meterRed))

            let unlit = height * (1 - fraction(level))
            context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: unlit)),
                         with: .color(Color(hex: 0x121318, opacity: 0.86)))

            // 3 pt segments with 1 pt gaps.
            var gaps = Path()
            var y = height - 4
            while y > 0 {
                gaps.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
                y -= 4
            }
            context.fill(gaps, with: .color(Color(hex: 0x0B0C0F, opacity: 0.9)))

            if let peak, peak > -60 {
                let position = fraction(peak)
                let color = position >= 0.9 ? Theme.meterRed : position >= 0.7 ? Theme.meterAmber : Theme.meterGreen
                context.fill(Path(CGRect(x: 0, y: height * (1 - position) - 1, width: size.width, height: 2)),
                             with: .color(color))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .accessibilityHidden(true)
    }
}
