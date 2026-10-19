import SwiftUI

/// Static transfer functions (input level to output level, in dB) for the gate and dynamics graphs.
enum ChannelDetailCurves {
    /// Expander ratios of the EXP2 / EXP3 / EXP4 gate modes.
    private static let expanderRatios: [Double] = [2, 3, 4]

    /// Gate / expander / ducker: output level for an input level.
    static func gate(input: Double, mode: Int, threshold: Double, range: Double) -> Double {
        switch mode {
        case 0, 1, 2:
            if input >= threshold { return input }
            let expanded = threshold + (input - threshold) * expanderRatios[mode]
            return max(expanded, input - range)
        case 4:
            return input >= threshold ? input - range : input
        default:
            return input >= threshold ? input : input - range
        }
    }

    /// Compressor with a soft knee `kneeWidth` dB wide, plus make-up gain.
    static func compressor(input: Double, threshold: Double, ratio: Double, kneeWidth: Double,
                           makeup: Double) -> Double {
        let over = input - threshold
        let output: Double
        if kneeWidth > 0 && abs(over) * 2 <= kneeWidth {
            let into = over + kneeWidth / 2
            output = input + (1 / ratio - 1) * into * into / (2 * kneeWidth)
        } else if over > 0 {
            output = threshold + over / ratio
        } else {
            output = input
        }
        return output + makeup
    }

    /// Downward expander: signals under the threshold are pushed down by `ratio`.
    static func expander(input: Double, threshold: Double, ratio: Double, makeup: Double) -> Double {
        let output = input >= threshold ? input : threshold + (input - threshold) * ratio
        return output + makeup
    }
}

/// Input level (x) against output level (y), with the 1:1 line and the threshold marked.
struct ChannelTransferCurve: View {
    let range: ClosedRange<Double>
    let gridStep: Double
    let threshold: Double
    let curve: (Double) -> Double

    var body: some View {
        Canvas { context, size in
            let span = range.upperBound - range.lowerBound
            func px(_ decibels: Double) -> CGFloat {
                size.width * CGFloat((decibels - range.lowerBound) / span)
            }
            func py(_ decibels: Double) -> CGFloat {
                size.height * CGFloat(1 - (decibels - range.lowerBound) / span)
            }

            var grid = Path()
            var mark = range.lowerBound
            while mark <= range.upperBound + 0.001 {
                grid.move(to: CGPoint(x: px(mark), y: 0))
                grid.addLine(to: CGPoint(x: px(mark), y: size.height))
                grid.move(to: CGPoint(x: 0, y: py(mark)))
                grid.addLine(to: CGPoint(x: size.width, y: py(mark)))
                mark += gridStep
            }
            context.stroke(grid, with: .color(.white.opacity(0.06)), lineWidth: 1)

            var unity = Path()
            unity.move(to: CGPoint(x: px(range.lowerBound), y: py(range.lowerBound)))
            unity.addLine(to: CGPoint(x: px(range.upperBound), y: py(range.upperBound)))
            context.stroke(unity, with: .color(.white.opacity(0.18)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

            var marker = Path()
            marker.move(to: CGPoint(x: px(threshold), y: 0))
            marker.addLine(to: CGPoint(x: px(threshold), y: size.height))
            context.stroke(marker, with: .color(Theme.accent.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            var line = Path()
            let steps = 160
            for step in 0...steps {
                let input = range.lowerBound + span * Double(step) / Double(steps)
                let point = CGPoint(x: px(input), y: py(curve(input)))
                if step == 0 {
                    line.move(to: point)
                } else {
                    line.addLine(to: point)
                }
            }
            var clipped = context
            clipped.clip(to: Path(CGRect(origin: .zero, size: size)))
            clipped.stroke(line, with: .color(Theme.accent),
                           style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))

            var label = range.lowerBound
            while label < range.upperBound - 0.001 {
                let text = Text(ParamFormat.plain(Float(label), decimals: 0))
                    .font(Theme.mono(10, .regular)).foregroundStyle(Theme.textMuted)
                context.draw(text, at: CGPoint(x: px(label) + 3, y: size.height - 9), anchor: .leading)
                if label > range.lowerBound {
                    context.draw(text, at: CGPoint(x: 4, y: py(label) - 7), anchor: .leading)
                }
                label += gridStep
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .background(Color(hex: 0x0D0E12), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }
}

/// Gain-reduction meter, fed by `/meters/6`: how many dB the gate or compressor is pulling the signal down.
struct GainReductionMeter: View {
    /// dB of reduction, 0 or more.
    let reduction: Float

    private static let span: Float = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("GAIN REDUCTION").sectionLabelStyle()
                Spacer()
                Text(reduction >= 0.5 ? "−\(String(format: "%.0f", reduction)) dB" : "0 dB")
                    .font(Theme.mono(13, .bold))
                    .foregroundStyle(reduction >= 0.5 ? Theme.amberText : Theme.textMuted)
            }
            RoundedRectangle(cornerRadius: 3)
                .fill(Theme.well)
                .frame(height: 8)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.meterAmber)
                            .frame(width: proxy.size.width * CGFloat(min(reduction, Self.span) / Self.span))
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.06), lineWidth: 1))
            HStack {
                ForEach(["0", "6", "12", "18", "24"], id: \.self) { tick in
                    Text(tick).font(Theme.mono(9, .regular)).foregroundStyle(Theme.textMuted)
                    if tick != "24" { Spacer() }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gain reduction")
        .accessibilityValue("\(Int(reduction)) dB")
    }
}

/// Title row of a processing card: name, status line and the section's on/off switch.
private struct ProcessingHeader: View {
    let title: String
    let onAddress: String
    let undoLabel: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            ParamSwitch(address: onAddress, title: L("On"), undoLabel: undoLabel)
                .frame(width: 100)
        }
    }
}

/// A caption above a control.
private struct CaptionedControl<Content: View>: View {
    let caption: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption).sectionLabelStyle()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private let knobColumns = [GridItem(.adaptive(minimum: 76), spacing: 8)]

// MARK: - Gate

/// Noise gate / expander / ducker page.
@MainActor
struct ChannelDetailGateTab: View {
    @Environment(Mixer.self) private var mixer
    @Environment(\.horizontalSizeClass) private var sizeClass
    let strip: Strip

    var body: some View {
        let base = strip.base
        let mode = mixer.param(XR18Params.gate(base, "mode")).int ?? 3
        let threshold = Double(mixer.realValue(XR18Params.gate(base, "thr"), XR18Params.gateThreshold) ?? -40)
        let reduction = Double(mixer.realValue(XR18Params.gate(base, "range"), XR18Params.gateRange) ?? 20)
        ScrollView {
            if sizeClass == .compact {
                VStack(spacing: 16) {
                    curveCard(mode: mode, threshold: threshold, reduction: reduction)
                    parameterCard
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    curveCard(mode: mode, threshold: threshold, reduction: reduction)
                        .frame(width: 360)
                    parameterCard
                }
            }
        }
    }

    private func curveCard(mode: Int, threshold: Double, reduction: Double) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TRANSFER · IN → OUT (dB)").sectionLabelStyle()
            ChannelTransferCurve(range: -80...0, gridStep: 20, threshold: threshold) { input in
                ChannelDetailCurves.gate(input: input, mode: mode, threshold: threshold, range: reduction)
            }
            GainReductionMeter(reduction: strip.gateReduction)
        }
        .detailCard()
    }

    private var parameterCard: some View {
        let base = strip.base
        let name = "\(strip.displayName) gate"
        return VStack(alignment: .leading, spacing: 14) {
            ProcessingHeader(title: L("Gate"), onAddress: XR18Params.gate(base, "on"), undoLabel: name)
            CaptionedControl(caption: L("MODE")) {
                ParamMenu(address: XR18Params.gate(base, "mode"), options: XR18Params.gateModes,
                          title: L("Gate mode"), undoLabel: L("\(name) mode"))
            }
            LazyVGrid(columns: knobColumns, spacing: 12) {
                ParamKnob(address: XR18Params.gate(base, "thr"), title: L("THRESH"),
                          range: XR18Params.gateThreshold, format: { ParamFormat.plain($0) + " dB" },
                          undoLabel: L("\(name) threshold"), tint: Theme.accent, width: 76)
                ParamKnob(address: XR18Params.gate(base, "range"), title: L("RANGE"),
                          range: XR18Params.gateRange, format: { String(format: "%.0f dB", $0) },
                          undoLabel: L("\(name) range"), width: 76)
                ParamKnob(address: XR18Params.gate(base, "attack"), title: L("ATTACK"),
                          range: XR18Params.gateAttack, format: { ParamFormat.time($0) },
                          undoLabel: L("\(name) attack"), width: 76)
                ParamKnob(address: XR18Params.gate(base, "hold"), title: L("HOLD"),
                          range: XR18Params.gateHold, format: { ParamFormat.time($0) },
                          undoLabel: L("\(name) hold"), width: 76)
                ParamKnob(address: XR18Params.gate(base, "release"), title: L("RELEASE"),
                          range: XR18Params.gateRelease, format: { ParamFormat.time($0) },
                          undoLabel: L("\(name) release"), width: 76)
            }
        }
        .detailCard()
    }
}

// MARK: - Dynamics

/// Compressor / expander page.
@MainActor
struct ChannelDetailDynamicsTab: View {
    @Environment(Mixer.self) private var mixer
    @Environment(\.horizontalSizeClass) private var sizeClass
    let strip: Strip

    var body: some View {
        let base = strip.base
        let isExpander = mixer.param(XR18Params.dyn(base, "mode")).int == 1
        let threshold = Double(mixer.realValue(XR18Params.dyn(base, "thr"), XR18Params.dynThreshold) ?? -20)
        let ratioIndex = mixer.param(XR18Params.dyn(base, "ratio")).int ?? 6
        let ratios = XR18Params.dynRatios
        let ratio = Double(ratios[min(max(ratioIndex, 0), ratios.count - 1)])
        let knee = Double(mixer.realValue(XR18Params.dyn(base, "knee"), XR18Params.dynKnee) ?? 0)
        let makeup = Double(mixer.realValue(XR18Params.dyn(base, "mgain"), XR18Params.dynMakeup) ?? 0)
        let shape = DynamicsShape(isExpander: isExpander, threshold: threshold, ratio: ratio,
                                  kneeWidth: knee * 3, makeup: makeup)
        ScrollView {
            if sizeClass == .compact {
                VStack(spacing: 16) {
                    curveCard(shape)
                    parameterCard
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    curveCard(shape)
                        .frame(width: 360)
                    parameterCard
                }
            }
        }
    }

    private func curveCard(_ shape: DynamicsShape) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TRANSFER · IN → OUT (dB)").sectionLabelStyle()
            ChannelTransferCurve(range: -60...0, gridStep: 10, threshold: shape.threshold) { input in
                shape.output(for: input)
            }
            GainReductionMeter(reduction: strip.dynReduction)
        }
        .detailCard()
    }

    private var parameterCard: some View {
        let base = strip.base
        let name = "\(strip.displayName) dynamics"
        return VStack(alignment: .leading, spacing: 14) {
            ProcessingHeader(title: L("Dynamics"), onAddress: XR18Params.dyn(base, "on"), undoLabel: name)
            HStack(spacing: 12) {
                CaptionedControl(caption: L("MODE")) {
                    ParamMenu(address: XR18Params.dyn(base, "mode"), options: XR18Params.dynModes,
                              title: L("Dynamics mode"), undoLabel: L("\(name) mode"))
                }
                CaptionedControl(caption: L("DETECTOR")) {
                    ParamMenu(address: XR18Params.dyn(base, "det"), options: XR18Params.detectors,
                              title: L("Detector"), undoLabel: L("\(name) detector"))
                }
                CaptionedControl(caption: L("ENVELOPE")) {
                    ParamMenu(address: XR18Params.dyn(base, "env"), options: XR18Params.envelopes,
                              title: L("Envelope"), undoLabel: L("\(name) envelope"))
                }
                CaptionedControl(caption: L("RATIO")) {
                    ParamMenu(address: XR18Params.dyn(base, "ratio"), options: XR18Params.dynRatioLabels,
                              title: L("Ratio"), undoLabel: L("\(name) ratio"))
                }
            }
            LazyVGrid(columns: knobColumns, spacing: 12) {
                ParamKnob(address: XR18Params.dyn(base, "thr"), title: L("THRESH"),
                          range: XR18Params.dynThreshold, format: { ParamFormat.plain($0) + " dB" },
                          undoLabel: L("\(name) threshold"), tint: Theme.accent, width: 76)
                ParamKnob(address: XR18Params.dyn(base, "knee"), title: L("KNEE"),
                          range: XR18Params.dynKnee, format: { String(format: "%.1f", $0) },
                          undoLabel: L("\(name) knee"), width: 76)
                ParamKnob(address: XR18Params.dyn(base, "mgain"), title: L("MAKEUP"),
                          range: XR18Params.dynMakeup, format: { ParamFormat.signed($0) + " dB" },
                          undoLabel: L("\(name) make-up gain"), width: 76)
                ParamKnob(address: XR18Params.dyn(base, "attack"), title: L("ATTACK"),
                          range: XR18Params.dynAttack, format: { ParamFormat.time($0) },
                          undoLabel: L("\(name) attack"), width: 76)
                ParamKnob(address: XR18Params.dyn(base, "hold"), title: L("HOLD"),
                          range: XR18Params.dynHold, format: { ParamFormat.time($0) },
                          undoLabel: L("\(name) hold"), width: 76)
                ParamKnob(address: XR18Params.dyn(base, "release"), title: L("RELEASE"),
                          range: XR18Params.dynRelease, format: { ParamFormat.time($0) },
                          undoLabel: L("\(name) release"), width: 76)
                ParamKnob(address: XR18Params.dyn(base, "mix"), title: L("MIX"),
                          range: XR18Params.dynMix, format: { String(format: "%.0f %%", $0) },
                          undoLabel: L("\(name) mix"), width: 76)
            }
            ParamSwitch(address: XR18Params.dyn(base, "auto"), title: L("Auto time"), undoLabel: L("\(name) auto time"))
        }
        .detailCard()
    }
}

/// What the dynamics section does to a level, for drawing its transfer curve.
private struct DynamicsShape {
    let isExpander: Bool
    let threshold: Double
    let ratio: Double
    /// Soft-knee width in dB. The mixer's knee setting 0...5 is drawn as 3 dB per step
    /// (an approximation: the real knee law isn't documented).
    let kneeWidth: Double
    let makeup: Double

    func output(for input: Double) -> Double {
        if isExpander {
            return ChannelDetailCurves.expander(input: input, threshold: threshold, ratio: ratio, makeup: makeup)
        }
        return ChannelDetailCurves.compressor(input: input, threshold: threshold, ratio: ratio,
                                              kneeWidth: kneeWidth, makeup: makeup)
    }
}
