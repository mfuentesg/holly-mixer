import SwiftUI

/// What is selected on the EQ graph: the low cut or one of the bands (0-based).
enum EQSelection: Hashable {
    case lowCut
    case band(Int)
}

/// Maps frequency and gain to points on the EQ graph (20 Hz...20 kHz, ±15 dB).
struct EQGraphLayout {
    static let topInset: CGFloat = 24
    static let bottomInset: CGFloat = 34
    static let gainLimit = 15.0

    let size: CGSize

    var plotHeight: CGFloat { max(size.height - Self.topInset - Self.bottomInset, 1) }

    func x(_ frequency: Double) -> CGFloat {
        CGFloat(EQScale.position(of: frequency)) * size.width
    }

    func y(_ gain: Double) -> CGFloat {
        Self.topInset + plotHeight / 2 - CGFloat(gain / Self.gainLimit) * plotHeight / 2
    }
}

/// The EQ page: on/off, the interactive graph and one card per band.
@MainActor
struct ChannelDetailEQTab: View {
    @Environment(Mixer.self) private var mixer
    @Environment(\.horizontalSizeClass) private var sizeClass
    let strip: Strip

    @State private var selection = EQSelection.band(0)
    @State private var confirmFlatten = false

    var body: some View {
        if sizeClass == .compact {
            ScrollView {
                VStack(spacing: 12) {
                    header
                    ChannelEQGraph(strip: strip, selection: $selection)
                        .frame(height: 280)
                    cards
                }
            }
        } else {
            VStack(spacing: 12) {
                header
                ChannelEQGraph(strip: strip, selection: $selection)
                    .frame(minHeight: 220)
                cards
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            ParamSwitch(address: XR18Params.eqOn(strip.base), title: L("EQ in"),
                        undoLabel: L("\(strip.displayName) EQ"))
                .frame(width: 130)
            Spacer()
            Button("Flatten…") { confirmFlatten = true }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textControl)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
                .confirmationDialog("Set every band of \(strip.displayName) to 0 dB?",
                                    isPresented: $confirmFlatten, titleVisibility: .visible) {
                    Button("Flatten EQ", role: .destructive, action: flatten)
                    Button("Cancel", role: .cancel) {}
                }
        }
    }

    private var cards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                if strip.hasPreamp {
                    LowCutCard(strip: strip, selection: $selection)
                }
                ForEach(0..<strip.eqBandCount, id: \.self) { index in
                    EQBandCard(strip: strip, index: index, selection: $selection)
                }
            }
        }
        .overlay(alignment: .trailing) {
            // A fade at the edge says there are more bands to scroll to.
            LinearGradient(colors: [Theme.background.opacity(0), Theme.background],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 36)
                .allowsHitTesting(false)
        }
        .frame(height: 188)
    }

    private func flatten() {
        let zero = XR18Params.eqGain.normalized(0)
        for band in 1...strip.eqBandCount {
            mixer.set(XR18Params.eq(strip.base, band: band, "g"), .float(zero),
                      label: L("\(strip.displayName) EQ flattened"))
        }
    }
}

/// One band's type menu and knobs.
private struct EQBandCard: View {
    @Environment(Mixer.self) private var mixer
    let strip: Strip
    let index: Int
    @Binding var selection: EQSelection

    var body: some View {
        let number = index + 1
        let band = EQModel.band(mixer, strip, index: index)
        let isSelected = selection == .band(index)
        let tint = isSelected ? Theme.accent : Theme.textControl
        let name = "\(strip.displayName) EQ \(number)"
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(Theme.mono(10, .heavy))
                    .foregroundStyle(isSelected ? Theme.onAccent : Theme.textPrimary)
                    .frame(width: 22, height: 22)
                    .background(isSelected ? Theme.accent : Color(hex: 0x2A2D33), in: Circle())
                Text("Band \(number)")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            ParamMenu(address: XR18Params.eq(strip.base, band: number, "type"),
                      options: EQBandType.names, title: L("Band \(number) type"), undoLabel: L("\(name) type"))
            HStack(spacing: 0) {
                ParamKnob(address: XR18Params.eq(strip.base, band: number, "f"), title: L("FREQ"),
                          range: XR18Params.eqFrequency, format: { ParamFormat.frequency($0) },
                          undoLabel: L("\(name) frequency"), tint: tint, dialSize: 40, width: 54)
                if band.type.hasGain {
                    ParamKnob(address: XR18Params.eq(strip.base, band: number, "g"), title: L("GAIN"),
                              range: XR18Params.eqGain, format: { ParamFormat.signed($0) },
                              undoLabel: L("\(name) gain"), tint: tint, bipolar: true,
                              resetPosition: 0.5, dialSize: 40, width: 54)
                }
                if band.type.hasQ {
                    ParamKnob(address: XR18Params.eq(strip.base, band: number, "q"), title: "Q",
                              range: XR18Params.eqQ, format: { ParamFormat.plain($0) },
                              undoLabel: "\(name) Q", tint: tint,
                              resetPosition: XR18Params.eqQ.normalized(1), dialSize: 40, width: 54)
                }
            }
        }
        .detailCard(highlighted: isSelected)
        .frame(width: 192)
        .contentShape(Rectangle())
        .onTapGesture { selection = .band(index) }
    }
}

/// The preamp low cut (high-pass filter) shown on the EQ page for channels.
private struct LowCutCard: View {
    @Environment(Mixer.self) private var mixer
    let strip: Strip
    @Binding var selection: EQSelection

    var body: some View {
        let isSelected = selection == .lowCut
        let tint = isSelected ? Theme.accent : Theme.textControl
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text("LC")
                    .font(Theme.mono(10, .heavy))
                    .foregroundStyle(Theme.textControl)
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(Theme.textTertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                Text("Low cut")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            ParamSwitch(address: XR18Params.preamp(strip.base, "hpon"), title: L("On"),
                        undoLabel: L("\(strip.displayName) low cut"))
            HStack {
                ParamKnob(address: XR18Params.preamp(strip.base, "hpf"), title: L("FREQ"),
                          range: XR18Params.lowCut, format: { ParamFormat.frequency($0) },
                          undoLabel: L("\(strip.displayName) low cut frequency"), tint: tint,
                          dialSize: 40, width: 54)
                Spacer()
                Text("12 dB/oct")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .detailCard(highlighted: isSelected)
        .frame(width: 192)
        .contentShape(Rectangle())
        .onTapGesture { selection = .lowCut }
    }
}

// MARK: - Graph

/// A node being dragged: where it started, so the drag is relative and never jumps.
private struct NodeDrag {
    let selection: EQSelection
    /// Position of the node along the frequency axis, 0...1.
    let startPosition: Double
    /// Gain as an OSC position, nil for bands without gain.
    let startGain: Float?
}

/// An in-progress pinch on the selected band.
private struct PinchState {
    let address: String
    let startQ: Float
    let label: String
}

/// A dot on the graph.
private struct EQNode: Identifiable {
    let selection: EQSelection
    let label: String
    let point: CGPoint
    let isDimmed: Bool
    var id: EQSelection { selection }
}

/// The big interactive EQ curve: drag nodes for frequency and gain, pinch for Q.
@MainActor
private struct ChannelEQGraph: View {
    @Environment(Mixer.self) private var mixer
    let strip: Strip
    @Binding var selection: EQSelection

    @State private var drag: NodeDrag?
    @State private var pinch: PinchState?

    var body: some View {
        let bands = EQModel.bands(mixer, strip)
        let isOn = EQModel.isOn(mixer, strip)
        let lowCutOn = EQModel.lowCutIsOn(mixer, strip)
        let lowCutHz = EQModel.lowCutFrequency(mixer, strip)
        let filters = EQModel.filterSet(mixer, strip)
        GeometryReader { proxy in
            let layout = EQGraphLayout(size: proxy.size)
            let nodes = makeNodes(layout: layout, bands: bands, isOn: isOn, lowCutOn: lowCutOn, lowCutHz: lowCutHz)
            ZStack(alignment: .topLeading) {
                EQGraphCanvas(
                    curve: filters.curve(count: 200),
                    selected: selectedCurve(bands: bands, isOn: isOn),
                    qHandle: qHandle(bands: bands, isOn: isOn),
                    isOn: isOn
                )
                Text("Drag a dot for frequency & gain · pinch for Q · double-tap to reset band")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: proxy.size.width)
                    .position(x: proxy.size.width / 2, y: proxy.size.height - 44)
                    .allowsHitTesting(false)
                ForEach(nodes) { node in
                    nodeView(node, layout: layout, bands: bands)
                }
                tooltip(layout: layout, bands: bands, lowCutHz: lowCutHz)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(Color(hex: 0x0D0E12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .simultaneousGesture(pinchGesture(bands: bands))
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("EQ curve for \(strip.displayName)")
    }

    // MARK: Geometry

    private func makeNodes(layout: EQGraphLayout, bands: [EQBand], isOn: Bool,
                           lowCutOn: Bool, lowCutHz: Float) -> [EQNode] {
        var nodes: [EQNode] = []
        if strip.hasPreamp {
            nodes.append(EQNode(selection: .lowCut, label: L("LC"),
                                point: CGPoint(x: layout.x(Double(lowCutHz)), y: layout.y(-3)),
                                isDimmed: !lowCutOn))
        }
        for (index, band) in bands.enumerated() {
            let gain = band.type.hasGain ? Double(band.gain) : 0
            nodes.append(EQNode(selection: .band(index), label: "\(index + 1)",
                                point: CGPoint(x: layout.x(Double(band.frequency)), y: layout.y(gain)),
                                isDimmed: !isOn))
        }
        return nodes
    }

    private func selectedCurve(bands: [EQBand], isOn: Bool) -> [Double]? {
        guard isOn, case .band(let index) = selection, bands.indices.contains(index) else { return nil }
        let band = bands[index]
        guard band.type.hasGain else { return nil }
        return EQFilterSet(bands: [band], lowCutFrequency: nil).curve(count: 200)
    }

    private func qHandle(bands: [EQBand], isOn: Bool) -> QHandle? {
        guard isOn, case .band(let index) = selection, bands.indices.contains(index) else { return nil }
        let band = bands[index]
        guard band.type.hasQ else { return nil }
        return QHandle(frequency: Double(band.frequency), gain: Double(band.gain), q: Double(band.q))
    }

    // MARK: Nodes

    private func nodeView(_ node: EQNode, layout: EQGraphLayout, bands: [EQBand]) -> some View {
        let isSelected = selection == node.selection
        let isLowCut = node.selection == .lowCut
        return EQNodeDot(label: node.label, isSelected: isSelected, isLowCut: isLowCut, isDimmed: node.isDimmed)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .position(node.point)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragChanged(node.selection, value.translation, layout: layout, bands: bands)
                    }
                    .onEnded { _ in dragEnded() }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { resetBand(node.selection) }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(node.selection, bands: bands))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAdjustableAction { direction in
                nudge(node.selection, up: direction == .increment, bands: bands)
            }
    }

    private func accessibilityLabel(_ node: EQSelection, bands: [EQBand]) -> String {
        switch node {
        case .lowCut:
            return L("Low cut, \(ParamFormat.frequency(EQModel.lowCutFrequency(mixer, strip))) Hz")
        case .band(let index):
            guard bands.indices.contains(index) else { return L("Band") }
            let band = bands[index]
            return L("Band \(index + 1), \(ParamFormat.frequency(band.frequency)) Hz, ")
                + "\(ParamFormat.signed(band.gain)) dB"
        }
    }

    private func dragChanged(_ node: EQSelection, _ translation: CGSize, layout: EQGraphLayout, bands: [EQBand]) {
        if drag?.selection != node {
            beginDrag(node, bands: bands)
        }
        guard let drag else { return }
        let position = min(max(drag.startPosition + Double(translation.width / layout.size.width), 0), 1)
        switch node {
        case .lowCut:
            let hertz = Float(EQScale.frequency(atPosition: position))
            mixer.setContinuous(XR18Params.preamp(strip.base, "hpf"), XR18Params.lowCut.normalized(hertz))
        case .band(let index):
            let number = index + 1
            mixer.setContinuous(XR18Params.eq(strip.base, band: number, "f"), Float(position))
            if let startGain = drag.startGain {
                let shift = Float(translation.height / layout.plotHeight)
                mixer.setContinuous(XR18Params.eq(strip.base, band: number, "g"),
                                    min(max(startGain - shift, 0), 1))
            }
        }
    }

    private func beginDrag(_ node: EQSelection, bands: [EQBand]) {
        if drag != nil { dragEnded() }
        selection = node
        switch node {
        case .lowCut:
            let address = XR18Params.preamp(strip.base, "hpf")
            let hertz = Double(EQModel.lowCutFrequency(mixer, strip))
            mixer.beginEdit(address)
            drag = NodeDrag(selection: node, startPosition: EQScale.position(of: hertz), startGain: nil)
        case .band(let index):
            guard bands.indices.contains(index) else { return }
            let band = bands[index]
            let number = index + 1
            mixer.beginEdit(XR18Params.eq(strip.base, band: number, "f"))
            var startGain: Float?
            if band.type.hasGain {
                mixer.beginEdit(XR18Params.eq(strip.base, band: number, "g"))
                startGain = XR18Params.eqGain.normalized(band.gain)
            }
            drag = NodeDrag(selection: node, startPosition: EQScale.position(of: Double(band.frequency)),
                            startGain: startGain)
        }
    }

    private func dragEnded() {
        guard let drag else { return }
        self.drag = nil
        switch drag.selection {
        case .lowCut:
            mixer.endEdit(XR18Params.preamp(strip.base, "hpf"), label: L("\(strip.displayName) low cut moved"))
        case .band(let index):
            let number = index + 1
            let label = "\(strip.displayName) EQ \(number) moved"
            mixer.endEdit(XR18Params.eq(strip.base, band: number, "f"), label: label)
            if drag.startGain != nil {
                mixer.endEdit(XR18Params.eq(strip.base, band: number, "g"), label: label)
            }
        }
    }

    private func resetBand(_ node: EQSelection) {
        guard case .band(let index) = node else { return }
        let number = index + 1
        let name = "\(strip.displayName) EQ \(number)"
        mixer.set(XR18Params.eq(strip.base, band: number, "g"), .float(XR18Params.eqGain.normalized(0)),
                  label: L("\(name) reset"))
        mixer.set(XR18Params.eq(strip.base, band: number, "q"), .float(XR18Params.eqQ.normalized(1)),
                  label: L("\(name) reset"))
    }

    /// VoiceOver adjust: gain for bands, frequency for the low cut.
    private func nudge(_ node: EQSelection, up: Bool, bands: [EQBand]) {
        switch node {
        case .lowCut:
            let address = XR18Params.preamp(strip.base, "hpf")
            let position = mixer.param(address).float ?? 0
            mixer.set(address, .float(min(max(position + (up ? 0.03 : -0.03), 0), 1)),
                      label: L("\(strip.displayName) low cut frequency"))
        case .band(let index):
            guard bands.indices.contains(index), bands[index].type.hasGain else { return }
            let address = XR18Params.eq(strip.base, band: index + 1, "g")
            let position = mixer.param(address).float ?? 0.5
            mixer.set(address, .float(min(max(position + (up ? 1 : -1) / 30, 0), 1)),
                      label: L("\(strip.displayName) EQ \(index + 1) gain"))
        }
    }

    // MARK: Pinch and tooltip

    private func pinchGesture(bands: [EQBand]) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinch == nil {
                    guard case .band(let index) = selection, bands.indices.contains(index),
                          bands[index].type.hasQ else { return }
                    let address = XR18Params.eq(strip.base, band: index + 1, "q")
                    mixer.beginEdit(address)
                    pinch = PinchState(address: address, startQ: bands[index].q,
                                       label: L("\(strip.displayName) EQ \(index + 1) Q"))
                }
                guard let pinch else { return }
                let q = min(max(pinch.startQ * Float(value.magnification), 0.3), 10)
                mixer.setContinuous(pinch.address, XR18Params.eqQ.normalized(q))
            }
            .onEnded { _ in
                if let pinch {
                    mixer.endEdit(pinch.address, label: pinch.label)
                }
                pinch = nil
            }
    }

    @ViewBuilder
    private func tooltip(layout: EQGraphLayout, bands: [EQBand], lowCutHz: Float) -> some View {
        switch selection {
        case .lowCut:
            if strip.hasPreamp {
                tooltipBox(layout: layout, point: CGPoint(x: layout.x(Double(lowCutHz)), y: layout.y(-3)),
                           items: [(ParamFormat.frequency(lowCutHz) + " Hz", Theme.textPrimary)])
            }
        case .band(let index):
            if bands.indices.contains(index) {
                let band = bands[index]
                let gain = band.type.hasGain ? Double(band.gain) : 0
                tooltipBox(layout: layout,
                           point: CGPoint(x: layout.x(Double(band.frequency)), y: layout.y(gain)),
                           items: tooltipItems(band))
            }
        }
    }

    private func tooltipItems(_ band: EQBand) -> [(String, Color)] {
        var items: [(String, Color)] = [(ParamFormat.frequency(band.frequency) + " Hz", Theme.textPrimary)]
        if band.type.hasGain {
            items.append((ParamFormat.signed(band.gain) + " dB", Theme.accentText))
        }
        if band.type.hasQ {
            items.append(("Q " + ParamFormat.plain(band.q), Theme.textSecondary))
        }
        return items
    }

    private func tooltipBox(layout: EQGraphLayout, point: CGPoint, items: [(String, Color)]) -> some View {
        HStack(spacing: 12) {
            ForEach(items.indices, id: \.self) { index in
                Text(items[index].0)
                    .font(Theme.mono(13, .semibold))
                    .foregroundStyle(items[index].1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 10, y: 8)
        .fixedSize()
        .position(x: min(max(point.x, 100), max(layout.size.width - 100, 100)),
                  y: max(point.y - 40, 24))
        .allowsHitTesting(false)
    }
}

/// The selected band's Q handles: where the curve is `q`-wide around `frequency`.
private struct QHandle {
    let frequency: Double
    let gain: Double
    let q: Double
}

/// The circle on the graph.
private struct EQNodeDot: View {
    let label: String
    let isSelected: Bool
    let isLowCut: Bool
    let isDimmed: Bool

    var body: some View {
        let size: CGFloat = isSelected ? 34 : 30
        Text(label)
            .font(Theme.mono(11, .heavy))
            .foregroundStyle(isSelected ? Theme.onAccent : (isLowCut ? Theme.textControl : Theme.textPrimary))
            .frame(width: size, height: size)
            .background(fill, in: Circle())
            .overlay(
                Circle().stroke(border, style: StrokeStyle(lineWidth: 2, dash: isLowCut && !isSelected ? [4, 3] : []))
            )
            .shadow(color: isSelected ? Theme.accent.opacity(0.3) : .black.opacity(0.5), radius: isSelected ? 6 : 4)
            .opacity(isDimmed ? 0.45 : 1)
    }

    private var fill: Color {
        if isSelected { return Theme.accent }
        return isLowCut ? Theme.background : Color(hex: 0x2A2D33)
    }

    private var border: Color {
        if isSelected { return .white }
        return isLowCut ? Theme.textTertiary : Theme.textControl
    }
}

/// Grid, labels and curves of the EQ graph.
private struct EQGraphCanvas: View {
    let curve: [Double]
    let selected: [Double]?
    let qHandle: QHandle?
    let isOn: Bool

    private static let frequencyMarks: [(hertz: Double, label: String)] = [
        (50, "50"), (100, "100"), (200, "200"), (500, "500"),
        (1000, "1k"), (2000, "2k"), (5000, "5k"), (10000, "10k"),
    ]
    private static let gainMarks: [Double] = [-15, -10, -5, 0, 5, 10, 15]

    var body: some View {
        Canvas { context, size in
            let layout = EQGraphLayout(size: size)
            drawGrid(&context, size: size, layout: layout)
            drawCurves(&context, size: size, layout: layout)
            drawQHandles(&context, layout: layout)
        }
    }

    private func drawGrid(_ context: inout GraphicsContext, size: CGSize, layout: EQGraphLayout) {
        var grid = Path()
        for mark in Self.frequencyMarks {
            let x = layout.x(mark.hertz)
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        for gain in Self.gainMarks where gain != 0 {
            let y = layout.y(gain)
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(grid, with: .color(.white.opacity(0.06)), lineWidth: 1)

        var zero = Path()
        zero.move(to: CGPoint(x: 0, y: layout.y(0)))
        zero.addLine(to: CGPoint(x: size.width, y: layout.y(0)))
        context.stroke(zero, with: .color(.white.opacity(0.18)), lineWidth: 1)

        for mark in Self.frequencyMarks {
            context.draw(
                Text(mark.label).font(Theme.mono(11, .regular)).foregroundStyle(Theme.textMuted),
                at: CGPoint(x: layout.x(mark.hertz), y: size.height - 14), anchor: .center)
        }
        for gain in Self.gainMarks {
            let sign = gain > 0 ? "+" : (gain < 0 ? "−" : "")
            let color = gain == 0 ? Theme.textSecondary : Theme.textDim
            context.draw(
                Text("\(sign)\(Int(abs(gain)))").font(Theme.mono(11, .regular)).foregroundStyle(color),
                at: CGPoint(x: 8, y: layout.y(gain)), anchor: .leading)
        }
    }

    private func drawCurves(_ context: inout GraphicsContext, size: CGSize, layout: EQGraphLayout) {
        if let selected {
            let line = curvePath(selected, size: size, layout: layout)
            context.fill(areaPath(line, size: size, layout: layout), with: .color(Theme.accent.opacity(0.12)))
            context.stroke(line, with: .color(Theme.accent),
                           style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
        }
        let total = curvePath(curve, size: size, layout: layout)
        context.fill(areaPath(total, size: size, layout: layout), with: .color(Color(hex: 0xF2F3F5, opacity: 0.06)))
        context.stroke(total, with: .color(isOn ? Theme.textPrimary : Theme.textDim),
                       style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
    }

    private func drawQHandles(_ context: inout GraphicsContext, layout: EQGraphLayout) {
        guard let qHandle else { return }
        let half = 0.5 / max(qHandle.q, 0.05)
        let left = layout.x(qHandle.frequency * pow(2, -half))
        let right = layout.x(qHandle.frequency * pow(2, half))
        let y = layout.y(qHandle.gain / 2)
        var line = Path()
        line.move(to: CGPoint(x: left, y: y))
        line.addLine(to: CGPoint(x: right, y: y))
        context.stroke(line, with: .color(Theme.accent), lineWidth: 1.5)
        for x in [left, right] {
            let handle = CGRect(x: x - 4, y: y - 12, width: 8, height: 24)
            context.fill(Path(roundedRect: handle, cornerRadius: 4), with: .color(Theme.accent))
        }
    }

    private func curvePath(_ values: [Double], size: CGSize, layout: EQGraphLayout) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let last = Double(values.count - 1)
        for (index, decibels) in values.enumerated() {
            let limit = EQGraphLayout.gainLimit + 2
            let point = CGPoint(x: size.width * CGFloat(Double(index) / last),
                                y: layout.y(min(max(decibels, -limit), limit)))
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }

    private func areaPath(_ line: Path, size: CGSize, layout: EQGraphLayout) -> Path {
        var area = line
        area.addLine(to: CGPoint(x: size.width, y: layout.y(0)))
        area.addLine(to: CGPoint(x: 0, y: layout.y(0)))
        area.closeSubpath()
        return area
    }
}
