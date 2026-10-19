import SwiftUI

/// Horizontal fader for the iPhone layouts. Grab the cap and drag: it moves relative to where
/// the finger started (no jumping to the touch). Double-tap anywhere returns it to 0 dB.
/// Only the cap takes drags, so vertical swipes elsewhere still scroll the list.
struct PhoneHorizontalFader: View {
    let value: Float
    /// Colour of the level line and the cap's centre mark (channel colour, or the bus colour in sends mode).
    var lineColor: Color = Theme.textControl
    var isMuted = false
    var capSize = CGSize(width: 28, height: 24)
    /// Width of the touch target around the cap.
    var hitWidth: CGFloat = 44
    var trackHeight: CGFloat = 5
    /// Strip whose live meter is drawn along the bottom edge.
    var meterStrip: Strip?
    var label = "Fader"
    var onTouchingChanged: (Bool) -> Void
    var onChange: (Float) -> Void

    static let unity: Float = 0.75
    /// Scale marks in dB.
    private static let marks: [Float] = [10, 5, 0, -5, -10, -20, -30, -40, -50]

    @State private var dragStartValue: Float?
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let inset = hitWidth / 2
            let travel = max(geometry.size.width - inset * 2, 1)
            let capX = inset + CGFloat(value) * travel

            ZStack(alignment: .topLeading) {
                scale(inset: inset, travel: travel)
                if let meterStrip {
                    PhoneMeterLine(strip: meterStrip)
                        .frame(width: travel, height: 2)
                        .position(x: inset + travel / 2, y: geometry.size.height - 1)
                }
                cap
                    .frame(width: hitWidth, height: geometry.size.height)
                    .contentShape(Rectangle())
                    .gesture(drag(travel: travel))
                    .position(x: capX, y: geometry.size.height / 2)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                onTouchingChanged(true)
                onChange(Self.unity)
                onTouchingChanged(false)
            }
        }
        .frame(minHeight: 36)
        .sensoryFeedback(.selection, trigger: value >= Self.unity)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(formatDecibels(value) + " dB")
        .accessibilityAdjustableAction { direction in
            let step: Float = 0.02
            let next = direction == .increment ? value + step : value - step
            onTouchingChanged(true)
            onChange(min(max(next, 0), 1))
            onTouchingChanged(false)
        }
    }

    private func drag(travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if dragStartValue == nil {
                    dragStartValue = value
                    isDragging = true
                    onTouchingChanged(true)
                }
                let delta = Float(gesture.translation.width / travel)
                onChange(min(max((dragStartValue ?? value) + delta, 0), 1))
            }
            .onEnded { _ in
                dragStartValue = nil
                isDragging = false
                onTouchingChanged(false)
            }
    }

    /// Recessed track, dB tick marks, the 0 dB line and the level line.
    private func scale(inset: CGFloat, travel: CGFloat) -> some View {
        Canvas { context, size in
            let midY = size.height / 2
            func x(_ position: Float) -> CGFloat { inset + CGFloat(position) * travel }

            let track = CGRect(x: inset - 12, y: midY - trackHeight / 2,
                               width: travel + 24, height: trackHeight)
            context.fill(Path(roundedRect: track, cornerRadius: trackHeight / 2), with: .color(Theme.well))
            context.stroke(Path(roundedRect: track.insetBy(dx: 0.5, dy: 0.5), cornerRadius: trackHeight / 2),
                           with: .color(.white.opacity(0.06)), lineWidth: 1)

            for db in Self.marks {
                let isUnity = db == 0
                let height: CGFloat = isUnity ? 8 : 4
                let tick = CGRect(x: x(decibelsToFader(db)) - 0.5, y: midY - trackHeight / 2 - 1 - height,
                                  width: 1, height: height)
                context.fill(Path(tick), with: .color(.white.opacity(isUnity ? 0.5 : 0.2)))
            }
            let unity = CGRect(x: x(Self.unity) - 0.5, y: midY - 9, width: 1, height: 18)
            context.fill(Path(unity), with: .color(.white.opacity(0.22)))

            let line = CGRect(x: inset, y: midY - 1.5, width: CGFloat(value) * travel, height: 3)
            context.fill(Path(roundedRect: line, cornerRadius: 1.5),
                         with: .color(lineColor.opacity(isMuted ? 0.3 : 0.9)))
        }
    }

    private var cap: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(LinearGradient(
                colors: isDragging ? [Color(hex: 0x555A63), Color(hex: 0x30333A)]
                                   : [Color(hex: 0x464A52), Color(hex: 0x2B2E34)],
                startPoint: .leading, endPoint: .trailing))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isDragging ? Theme.accent : Color.white.opacity(0.16), lineWidth: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 1)
                    .fill(lineColor)
                    .frame(width: 2, height: capSize.height * 0.65)
            }
            .frame(width: capSize.width, height: capSize.height)
            .shadow(color: .black.opacity(isDragging ? 0.7 : 0.55), radius: isDragging ? 9 : 5, y: 3)
            .scaleEffect(isDragging ? 1.08 : 1)
            .opacity(isMuted ? 0.55 : 1)
            .animation(.spring(duration: 0.18), value: isDragging)
    }
}

/// Thin horizontal level meter: green to -18 dB, amber to -6 dB, red above.
struct PhoneMeterLine: View {
    let strip: Strip

    var body: some View {
        let level = strip.meter
        Canvas { context, size in
            let fraction = CGFloat(min(max((level + 60) / 60, 0), 1))
            let zones: [PhoneMeterZone] = [
                PhoneMeterZone(start: 0, end: 0.7, color: Theme.meterGreen),
                PhoneMeterZone(start: 0.7, end: 0.9, color: Theme.meterAmber),
                PhoneMeterZone(start: 0.9, end: 1, color: Theme.meterRed),
            ]
            for zone in zones where fraction > zone.start {
                let end = min(fraction, zone.end)
                let rect = CGRect(x: size.width * zone.start, y: 0,
                                  width: size.width * (end - zone.start), height: size.height)
                context.fill(Path(rect), with: .color(zone.color.opacity(0.85)))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct PhoneMeterZone {
    let start: CGFloat
    let end: CGFloat
    let color: Color
}
