import SwiftUI
import UIKit

/// Locked volunteer layout (Service.dc.html): a few big limited faders and nothing else. Leaving needs the PIN.
@MainActor
struct ServiceModeView: View {
    @Environment(Mixer.self) private var mixer
    private let store = ServiceLayoutStore.shared
    /// When set (editor preview) Exit calls this directly instead of asking for the PIN.
    private let onPreviewExit: (() -> Void)?

    @State private var showingPIN = false
    private let scenes = SceneStore.shared

    init(onPreviewExit: (() -> Void)? = nil) {
        self.onPreviewExit = onPreviewExit
    }

    private var cards: [ServiceCard] {
        store.layout.items.compactMap { item in
            item.strip(in: mixer).map { ServiceCard(item: item, strip: $0) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            sceneFooter
        }
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $showingPIN) {
            ServicePINSheet(store: store) { mixer.presentedScreen = nil }
                .presentationDetents([.large])
        }
        .onAppear {
            store.seedIfNeeded(mixer)
            scenes.attach(mixer)
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accentText)
                .frame(width: 40, height: 40)
                .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("Service Mode")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(store.layout.title) · only these controls are live")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            connectionPill
            if let phone = soundLeadURL {
                Button {
                    UIApplication.shared.open(phone)
                } label: {
                    Text("Call sound lead")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textBright)
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.borderStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Button(action: requestExit) {
                HStack(spacing: 8) {
                    Image(systemName: "lock")
                    Text("Exit · PIN")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.14), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(onPreviewExit == nil ? "Exit Service Mode, PIN required" : "Close preview")
        }
        .padding(.horizontal, 20)
        .frame(height: 72)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    /// NOW → NEXT bar with a hold-to-recall button (bottom of Service.dc.html).
    @ViewBuilder
    private var sceneFooter: some View {
        if let next = scenes.stepTarget(1) {
            let now = scenes.scene(scenes.show.currentSceneID)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("NOW").sectionLabelStyle()
                    Text(now?.name ?? "—")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                }
                Image(systemName: "arrow.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(next.note.isEmpty ? "NEXT" : "NEXT · \(next.note.uppercased())")
                        .sectionLabelStyle(Theme.accentText)
                        .lineLimit(1)
                    Text(next.name)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HoldToRecallButton(label: "go to \(next.name)", title: "Hold to go to \(next.name)",
                                   height: 64, cornerRadius: 14) {
                    scenes.recall(next.id, fade: scenes.fadeFaders)
                }
                .frame(width: 300)
            }
            .padding(.horizontal, 20)
            .frame(height: 96)
            .background(Theme.surface)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
    }

    private var soundLeadURL: URL? {
        let digits = (store.layout.soundLeadPhone ?? "").filter { $0.isNumber || $0 == "+" }
        return digits.isEmpty ? nil : URL(string: "tel:\(digits)")
    }

    private func requestExit() {
        if let onPreviewExit {
            onPreviewExit()
        } else {
            showingPIN = true
        }
    }

    private var connectionPill: some View {
        let connected = mixer.status == .connected
        let text = mixer.isDemo ? "Demo" : connected ? "Connected" : "Not connected"
        let tint = mixer.isDemo ? Theme.demo : connected ? Theme.meterGreen : Theme.meterAmber
        let textColor = mixer.isDemo ? Theme.demoText : connected ? Theme.greenText : Theme.amberText
        return HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(text)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(textColor)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(tint.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        let list = cards
        if list.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Text("Nothing to control")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("This layout is empty. Ask the sound lead.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            GeometryReader { geometry in
                let spacing: CGFloat = 16
                let available = geometry.size.width - 40
                let fit = (available - spacing * CGFloat(list.count - 1)) / CGFloat(list.count)
                let cardWidth = max(fit, 230)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: spacing) {
                        ForEach(list) { card in
                            ServiceFaderCard(card: card)
                                .frame(width: cardWidth)
                        }
                    }
                    .padding(20)
                    .frame(minWidth: geometry.size.width)
                    .frame(height: geometry.size.height)
                }
                .scrollDisabled(fit >= 230)
            }
        }
    }
}

/// A layout item paired with the live strip it controls.
struct ServiceCard: Identifiable {
    let item: ServiceItem
    let strip: Strip
    var id: UUID { item.id }
}

/// One volunteer column: colour bar, name, big fader with meter, dB readout and mute button.
@MainActor
struct ServiceFaderCard: View {
    @Environment(Mixer.self) private var mixer
    let card: ServiceCard

    private var item: ServiceItem { card.item }
    private var strip: Strip { card.strip }
    private var color: Color { item.color(for: strip) }
    private var isMuted: Bool { !strip.isOn }

    var body: some View {
        VStack(spacing: 12) {
            Rectangle()
                .fill(color)
                .frame(height: 6)
                .opacity(isMuted ? 0.4 : 1)
                .padding(.horizontal, -16)
            titles
            HStack(spacing: 10) {
                fader
                MeterView(level: strip.meter, peak: strip.peak)
                    .frame(width: 12)
            }
            .padding(.vertical, 12)
            readout
            muteButton
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .background(isMuted ? Color(hex: 0x141012) : Theme.strip, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(isMuted ? Theme.mute.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var titles: some View {
        VStack(spacing: 2) {
            Text(item.label)
                .font(Theme.rounded(26, .heavy))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(serviceDetail(for: strip))
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
    }

    private var fader: some View {
        ServiceFader(
            value: strip.fader,
            lower: item.lowerFader,
            upper: item.upperFader,
            minText: serviceFormatDB(item.minDB),
            maxText: serviceFormatDB(item.maxDB),
            color: color,
            isMuted: isMuted,
            label: item.label,
            onTouchingChanged: { mixer.setTouching(strip, .fader, $0) },
            onChange: { mixer.setLevel(strip, .fader, to: item.clamped($0)) }
        )
    }

    private var readout: some View {
        Text("\(formatDecibels(strip.fader)) dB")
            .font(Theme.mono(18, .bold))
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var muteButton: some View {
        if item.allowMute {
            Button {
                mixer.toggleMute(strip)
            } label: {
                Text(isMuted ? "MUTED" : "MUTE")
                    .font(.system(size: 16, weight: .heavy))
                    .tracking(1)
                    .foregroundStyle(isMuted ? Color.white : Theme.textBright)
                    .frame(maxWidth: .infinity)
                    .frame(height: 72)
                    .background(isMuted ? Theme.mute : Theme.control, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(isMuted ? Theme.muteBorder : Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: isMuted ? Theme.mute.opacity(0.45) : .clear, radius: 12)
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.impact(weight: .medium), trigger: isMuted)
            .accessibilityLabel((isMuted ? "Unmute " : "Mute ") + item.label)
        } else {
            Text(isMuted ? "MUTED" : "FADER ONLY")
                .font(.system(size: 12, weight: .bold))
                .tracking(1)
                .foregroundStyle(isMuted ? Theme.mute : Theme.textDim)
                .frame(maxWidth: .infinity)
                .frame(height: 72)
        }
    }
}

/// "Pulpito · ch 1", "Aux In", "Main LR".
@MainActor
func serviceDetail(for strip: Strip) -> String {
    if case .channel(let number) = strip.kind {
        return strip.name.isEmpty ? "Ch \(number)" : "\(strip.name) · ch \(number)"
    }
    return strip.displayName
}

// MARK: - Editor

/// Editor where the sound lead builds the Service Mode layout.
@MainActor
struct ServiceEditorView: View {
    @Environment(Mixer.self) private var mixer
    private let store = ServiceLayoutStore.shared

    @State private var layout = ServiceLayout()
    @State private var previewing = false
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            ScreenTopBar(title: "Service Mode", subtitle: "Build the layout volunteers will see") {
                startButton
            }
            List {
                titleSection
                itemsSection
                ServicePINSection(store: store)
                actionsSection
            }
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
        }
        .background(Theme.background.ignoresSafeArea())
        .onAppear {
            store.seedIfNeeded(mixer)
            layout = store.layout
            loaded = true
        }
        .onChange(of: layout) { _, newValue in
            if loaded { store.replace(newValue) }
        }
        .fullScreenCover(isPresented: $previewing) {
            ServiceModeView(onPreviewExit: { previewing = false })
        }
    }

    private var startButton: some View {
        Button {
            mixer.presentedScreen = .serviceMode
        } label: {
            Text("Start Service Mode")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var titleSection: some View {
        Section {
            TextField("Layout title", text: $layout.title)
                .font(.system(size: 17))
                .foregroundStyle(Theme.textPrimary)
                .frame(minHeight: 44)
                .listRowBackground(Theme.card)
            TextField("Sound lead phone (shows a “Call sound lead” button)", text: Binding(
                get: { layout.soundLeadPhone ?? "" },
                set: { layout.soundLeadPhone = $0.isEmpty ? nil : $0 }
            ))
            .keyboardType(.phonePad)
            .font(.system(size: 17))
            .foregroundStyle(Theme.textPrimary)
            .frame(minHeight: 44)
            .listRowBackground(Theme.card)
        } header: {
            Text("Layout title").sectionLabelStyle()
        }
    }

    private var itemsSection: some View {
        Section {
            ForEach($layout.items) { $item in
                ServiceItemRow(item: $item)
                    .listRowBackground(Theme.card)
            }
            .onMove { layout.items.move(fromOffsets: $0, toOffset: $1) }
            .onDelete { layout.items.remove(atOffsets: $0) }
            addMenu
                .listRowBackground(Theme.card)
        } header: {
            Text("Faders · drag to reorder").sectionLabelStyle()
        } footer: {
            Text("Volunteers only see these faders, in this order, and cannot go past the limits.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
        }
    }

    private var addMenu: some View {
        Menu {
            Section("Inputs") { ForEach(mixer.inputs) { addButton($0) } }
            Section("Buses") { ForEach(mixer.buses) { addButton($0) } }
            Section("Main") { addButton(mixer.main) }
        } label: {
            Label("Add fader", systemImage: "plus.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accentText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 44)
        }
    }

    private func addButton(_ strip: Strip) -> some View {
        Button(serviceDetail(for: strip)) {
            layout.items.append(ServiceItem(label: strip.displayName, base: strip.base, colorIndex: nil,
                                            minDB: -20, maxDB: 0, allowMute: true))
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                previewing = true
            } label: {
                Label("Preview (live faders)", systemImage: "eye")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textBright)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 44)
            }
            .listRowBackground(Theme.card)
        } footer: {
            Text("Preview controls the real mixer, within the limits. Exit needs no PIN there.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
        }
    }
}

/// Editor row: label, colour, limits and mute permission for one fader.
@MainActor
private struct ServiceItemRow: View {
    @Environment(Mixer.self) private var mixer
    @Binding var item: ServiceItem

    private var strip: Strip? { item.strip(in: mixer) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(strip.map { item.color(for: $0) } ?? Theme.textDim)
                    .frame(width: 14, height: 14)
                TextField("Label", text: $item.label)
                    .font(Theme.rounded(20, .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minHeight: 44)
                colorMenu
            }
            Text(strip.map(serviceDetail(for:)) ?? "Not on this mixer")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            limitSlider(title: "Min", value: minBinding)
            limitSlider(title: "Max", value: maxBinding)
            Toggle("Volunteer may mute", isOn: $item.allowMute)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textControl)
                .tint(Theme.accent)
                .frame(minHeight: 44)
        }
        .padding(.vertical, 6)
    }

    private var minBinding: Binding<Float> {
        Binding(get: { item.minDB }, set: { item.minDB = min($0, item.maxDB - 1) })
    }

    private var maxBinding: Binding<Float> {
        Binding(get: { item.maxDB }, set: { item.maxDB = max($0, item.minDB + 1) })
    }

    private func limitSlider(title: String, value: Binding<Float>) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .sectionLabelStyle()
                .frame(width: 34, alignment: .leading)
            Slider(value: value, in: -60...10, step: 0.5)
                .tint(Theme.accent)
                .accessibilityLabel("\(item.label) \(title.lowercased()) limit")
                .accessibilityValue("\(serviceFormatDB(value.wrappedValue)) dB")
            Text("\(serviceFormatDB(value.wrappedValue)) dB")
                .font(Theme.mono(14, .bold))
                .foregroundStyle(Theme.textBright)
                .frame(width: 80, alignment: .trailing)
        }
        .frame(minHeight: 44)
    }

    private var colorMenu: some View {
        Menu {
            Button("Strip colour") { item.colorIndex = nil }
            ForEach(0..<8, id: \.self) { index in
                Button("Colour \(index + 1)") { item.colorIndex = index }
            }
        } label: {
            Image(systemName: "paintpalette")
                .font(.system(size: 18))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Colour")
    }
}

/// Set or change the exit PIN: current PIN once, new PIN twice.
@MainActor
private struct ServicePINSection: View {
    let store: ServiceLayoutStore

    @State private var current = ""
    @State private var newPIN = ""
    @State private var confirm = ""
    @State private var message: String?
    @State private var succeeded = false

    var body: some View {
        Section {
            pinField("Current PIN", text: $current)
            pinField("New PIN (4 digits)", text: $newPIN)
            pinField("Repeat new PIN", text: $confirm)
            Button("Save PIN", action: save)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(canSave ? Theme.accentText : Theme.textDim)
                .frame(minHeight: 44)
                .disabled(!canSave)
                .listRowBackground(Theme.card)
            if let message {
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(succeeded ? Theme.greenText : Theme.mute)
                    .listRowBackground(Theme.card)
            }
        } header: {
            Text("Exit PIN").sectionLabelStyle()
        } footer: {
            Text(store.hasCustomPIN ? "A custom PIN is set." : "The factory PIN is still active. Set your own.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
        }
    }

    private var canSave: Bool {
        let length = ServiceLayoutStore.pinLength
        return current.count == length && newPIN.count == length && confirm.count == length
    }

    private func pinField(_ title: String, text: Binding<String>) -> some View {
        SecureField(title, text: text)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .font(Theme.mono(17, .semibold))
            .foregroundStyle(Theme.textPrimary)
            .frame(minHeight: 44)
            .listRowBackground(Theme.card)
            .onChange(of: text.wrappedValue) { _, value in
                let digits = String(value.filter(\.isNumber).prefix(ServiceLayoutStore.pinLength))
                if digits != value { text.wrappedValue = digits }
            }
    }

    private func save() {
        if !store.verifyPIN(current) {
            fail("Current PIN is wrong.")
        } else if newPIN != confirm {
            fail("The new PINs don't match.")
        } else {
            store.setPIN(newPIN)
            current = ""
            newPIN = ""
            confirm = ""
            succeeded = true
            message = "PIN saved."
        }
    }

    private func fail(_ text: String) {
        succeeded = false
        message = text
    }
}
