import SwiftUI

/// The arc of a rotary knob: a 270 degree track with the value drawn over it.
struct KnobDial: View {
    /// 0...1 along the arc.
    let fraction: Float
    var tint: Color = Theme.textControl
    /// Draw the value from the middle of the arc (for gains that can be negative).
    var bipolar = false
    var lineWidth: CGFloat = 4

    var body: some View {
        let sweep = 0.75
        let position = Double(min(max(fraction, 0), 1)) * sweep
        let middle = sweep / 2
        let from = bipolar ? min(middle, position) : 0
        let to = bipolar ? max(middle, position) : max(position, 0.01)
        ZStack {
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(Color(hex: 0x2A2D33), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: from, to: max(to, from + 0.01))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
        .rotationEffect(.degrees(135))
        .padding(lineWidth / 2 + 1)
    }
}

/// A rotary control for one continuous OSC parameter. Drag up/down to change it, double-tap to reset.
/// Edits go through `beginEdit` / `setContinuous` / `endEdit`, so one drag is one undo step.
@MainActor
struct ParamKnob: View {
    @Environment(Mixer.self) private var mixer
    let address: String
    /// Short upper-case caption, e.g. "FREQ".
    let title: String
    let range: ParamRange
    let format: (Float) -> String
    /// Start of the undo label, e.g. "Pulpito EQ 3 frequency"; the new value is appended.
    let undoLabel: String
    var tint: Color = Theme.textControl
    var bipolar = false
    /// OSC position to return to on double-tap.
    var resetPosition: Float?
    var dialSize: CGFloat = 44
    var width: CGFloat = 60

    @State private var startPosition: Float?

    /// Full range per this many points of vertical drag.
    private let dragLength: CGFloat = 180

    var body: some View {
        let stored = mixer.param(address).float
        let position = stored ?? resetPosition ?? 0
        VStack(spacing: 2) {
            KnobDial(fraction: position, tint: tint, bipolar: bipolar)
                .frame(width: dialSize, height: dialSize)
            Text(stored == nil ? "—" : format(range.value(position)))
                .font(Theme.mono(12, .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(width: width)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .gesture(drag(from: position))
        .onTapGesture(count: 2) {
            if let resetPosition { commit(resetPosition) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.capitalized)
        .accessibilityValue(stored == nil ? L("unknown") : format(range.value(position)))
        .accessibilityAdjustableAction { direction in
            let step: Float = 0.02
            commit(min(max(position + (direction == .increment ? step : -step), 0), 1))
        }
    }

    /// A knob only turns after a short press, so a swipe that starts on it still scrolls the page.
    private func drag(from position: Float) -> some Gesture {
        LongPressGesture(minimumDuration: 0.15)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                if startPosition == nil {
                    startPosition = position
                    mixer.beginEdit(address)
                }
                let delta = Float(-drag.translation.height / dragLength)
                mixer.setContinuous(address, min(max((startPosition ?? position) + delta, 0), 1))
            }
            .onEnded { _ in
                guard startPosition != nil else { return }
                startPosition = nil
                endLabel()
            }
    }

    private func commit(_ position: Float) {
        mixer.beginEdit(address)
        mixer.setContinuous(address, position)
        endLabel()
    }

    private func endLabel() {
        let value = range.value(mixer.param(address).float ?? 0)
        mixer.endEdit(address, label: "\(undoLabel) \(format(value))")
    }
}

/// An on/off switch drawn like the design's: 44 x 26 pt pill with a white thumb.
struct SwitchPill: View {
    let isOn: Bool
    var tint: Color = Theme.accent

    var body: some View {
        Capsule()
            .fill(isOn ? tint : Color(hex: 0x3A3E45))
            .frame(width: 44, height: 26)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(Color.white).frame(width: 22, height: 22).padding(2)
            }
            .animation(.easeOut(duration: 0.15), value: isOn)
    }
}

/// A titled on/off row bound to an int OSC address (0 / 1).
struct ParamSwitch: View {
    @Environment(Mixer.self) private var mixer
    let address: String
    let title: String
    /// Start of the undo label, e.g. "Pulpito low cut"; " on" or " off" is appended.
    let undoLabel: String
    var tint: Color = Theme.accent
    /// When set, called instead of switching ON (used to ask for confirmation first).
    var confirmTurnOn: (() -> Void)?

    var body: some View {
        let isOn = mixer.param(address).bool ?? false
        Button {
            if !isOn, let confirmTurnOn {
                confirmTurnOn()
            } else {
                mixer.set(address, .int(isOn ? 0 : 1), label: L("\(undoLabel) \(isOn ? L("off") : L("on"))"))
            }
        } label: {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textBright)
                Spacer(minLength: 8)
                SwitchPill(isOn: isOn, tint: tint)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? L("on") : L("off"))
    }
}

/// A drop-down for an int OSC parameter that indexes into `options`.
struct ParamMenu: View {
    @Environment(Mixer.self) private var mixer
    let address: String
    let options: [String]
    let title: String
    /// Start of the undo label; the chosen option is appended.
    let undoLabel: String

    var body: some View {
        let current = mixer.param(address).int
        let currentName = current.flatMap { options.indices.contains($0) ? options[$0] : nil }
        Menu {
            ForEach(options.indices, id: \.self) { index in
                Button {
                    mixer.set(address, .int(Int32(index)), label: "\(undoLabel) \(options[index])")
                } label: {
                    if current == index {
                        Label(options[index], systemImage: "checkmark")
                    } else {
                        Text(options[index])
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(currentName ?? "—")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textControl)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
        .accessibilityValue(currentName ?? "unknown")
    }
}

/// Rounded panel used for the cards on the detail page.
struct DetailCardBackground: ViewModifier {
    var highlighted = false

    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(highlighted ? Theme.accent.opacity(0.08) : Theme.surface,
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(highlighted ? Theme.accent.opacity(0.7) : Theme.border,
                            lineWidth: highlighted ? 1.5 : 1)
            )
    }
}

extension View {
    func detailCard(highlighted: Bool = false) -> some View {
        modifier(DetailCardBackground(highlighted: highlighted))
    }
}
