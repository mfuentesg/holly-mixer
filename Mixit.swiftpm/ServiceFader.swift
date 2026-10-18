import SwiftUI

/// Big vertical fader for volunteers. The allowed range is shaded and the value can never leave it.
/// Dragging anywhere on the track is relative to where the finger landed, so the cap never jumps.
struct ServiceFader: View {
    let value: Float
    /// Allowed range as fader positions 0...1.
    let lower: Float
    let upper: Float
    let minText: String
    let maxText: String
    let color: Color
    var isMuted = false
    let label: String
    var onTouchingChanged: (Bool) -> Void
    var onChange: (Float) -> Void

    private let capSize = CGSize(width: 80, height: 72)
    private let unity: Float = 0.75

    @State private var dragStartValue: Float?

    var body: some View {
        GeometryReader { geometry in
            let travel = max(geometry.size.height - capSize.height, 1)
            let trackX = max(capSize.width / 2 + 4, (geometry.size.width - 70) / 2)
            ZStack(alignment: .topLeading) {
                track(travel: travel, trackX: trackX)
                limitLabel("max \(maxText)", position: upper, travel: travel, x: trackX)
                limitLabel("min \(minText)", position: lower, travel: travel, x: trackX)
                cap
                    .position(x: trackX, y: y(value, travel: travel))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(drag(travel: travel))
        }
        .frame(minHeight: 200)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(formatDecibels(value)) dB, limited between \(minText) and \(maxText)")
        .accessibilityAdjustableAction { direction in
            let db = faderToDecibels(value)
            let current = db.isFinite ? db : -90
            let next = direction == .increment ? current + 1 : current - 1
            onTouchingChanged(true)
            onChange(clamp(decibelsToFader(next)))
            onTouchingChanged(false)
        }
    }

    private func clamp(_ position: Float) -> Float {
        min(max(position, lower), upper)
    }

    private func y(_ position: Float, travel: CGFloat) -> CGFloat {
        capSize.height / 2 + CGFloat(1 - min(max(position, 0), 1)) * travel
    }

    private func drag(travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if dragStartValue == nil {
                    dragStartValue = value
                    onTouchingChanged(true)
                }
                let delta = Float(-gesture.translation.height / travel)
                onChange(clamp((dragStartValue ?? value) + delta))
            }
            .onEnded { _ in
                dragStartValue = nil
                onTouchingChanged(false)
            }
    }

    private func track(travel: CGFloat, trackX: CGFloat) -> some View {
        let top = y(upper, travel: travel)
        let bottom = y(lower, travel: travel)
        let levelTop = y(value, travel: travel)
        let end = y(0, travel: travel)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.well)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.06), lineWidth: 1))
                .frame(width: 10, height: end - capSize.height / 2 + 12)
                .position(x: trackX, y: (end + capSize.height / 2) / 2)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.white.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
                .frame(width: 22, height: max(bottom - top, 2))
                .position(x: trackX, y: (top + bottom) / 2)
            Rectangle()
                .fill(Color.white.opacity(0.25))
                .frame(width: capSize.width, height: 1)
                .position(x: trackX, y: y(unity, travel: travel))
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(isMuted ? 0.3 : 0.9))
                .frame(width: 6, height: max(end - levelTop, 0))
                .position(x: trackX, y: (end + levelTop) / 2)
        }
        .allowsHitTesting(false)
    }

    private func limitLabel(_ text: String, position: Float, travel: CGFloat, x: CGFloat) -> some View {
        Text(text)
            .font(Theme.mono(11, .regular))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize()
            .position(x: x + capSize.width / 2 + 8 + 30, y: y(position, travel: travel))
            .allowsHitTesting(false)
    }

    private var cap: some View {
        VStack(spacing: 6) {
            grip
            grip
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 60, height: 3)
            grip
            grip
        }
        .frame(width: capSize.width, height: capSize.height)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(LinearGradient(
                colors: [Color(hex: 0x4A4E57), Color(hex: 0x2B2E34)], startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 11, y: 8)
        .opacity(isMuted ? 0.6 : 1)
        .allowsHitTesting(false)
    }

    private var grip: some View {
        Rectangle().fill(Color.white.opacity(0.26)).frame(width: 48, height: 1)
    }
}
