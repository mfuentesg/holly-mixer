import SwiftUI

/// Horizontal shake used for a wrong PIN; animate `shakes` by 1 to play it.
struct ServiceShakeEffect: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 12 * sin(shakes * .pi * 4), y: 0))
    }
}

/// Four dots over a numeric keypad. Edits `entry`; the caller reacts when it reaches `length` digits.
@MainActor
struct ServicePINPad: View {
    @Binding var entry: String
    var length = ServiceLayoutStore.pinLength
    var isDisabled = false
    /// Increase to shake the dots and keypad.
    var shakes = 0

    private let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]]

    var body: some View {
        VStack(spacing: 28) {
            dots
            VStack(spacing: 14) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: 14) {
                        ForEach(row, id: \.self) { digit in key(digit) }
                    }
                }
                HStack(spacing: 14) {
                    Color.clear.frame(width: 76, height: 76)
                    key("0")
                    deleteKey
                }
            }
        }
        .modifier(ServiceShakeEffect(shakes: CGFloat(shakes)))
        .animation(.easeOut(duration: 0.45), value: shakes)
        .opacity(isDisabled ? 0.4 : 1)
        .allowsHitTesting(!isDisabled)
    }

    private var dots: some View {
        HStack(spacing: 18) {
            ForEach(0..<length, id: \.self) { index in
                Circle()
                    .fill(index < entry.count ? Theme.accent : Color.clear)
                    .overlay(Circle().stroke(index < entry.count ? Theme.accent : Theme.textMuted, lineWidth: 2))
                    .frame(width: 18, height: 18)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("PIN")
        .accessibilityValue("\(entry.count) of \(length) digits entered")
    }

    private func key(_ digit: String) -> some View {
        Button {
            if entry.count < length { entry.append(digit) }
        } label: {
            Text(digit)
                .font(Theme.mono(30, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 76, height: 76)
                .background(Theme.control, in: Circle())
                .overlay(Circle().stroke(Theme.borderStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(digit)
    }

    private var deleteKey: some View {
        Button {
            if !entry.isEmpty { entry.removeLast() }
        } label: {
            Image(systemName: "delete.left")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 76, height: 76)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Delete")
    }
}

/// Sheet that asks for the PIN before leaving Service Mode; three wrong tries lock entry for 30 seconds.
@MainActor
struct ServicePINSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: ServiceLayoutStore
    let onSuccess: () -> Void

    @State private var entry = ""
    @State private var shakes = 0

    var body: some View {
        VStack(spacing: 26) {
            Image(systemName: "lock.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.accentText)
            Text("Enter PIN to exit")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            status
            ServicePINPad(entry: $entry, isDisabled: store.isLockedOut(), shakes: shakes)
            Button("Cancel") { dismiss() }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(minHeight: 44)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .onChange(of: entry) { _, newValue in
            if newValue.count == ServiceLayoutStore.pinLength { submit(newValue) }
        }
    }

    private var status: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = store.lockedUntil.map { Int(ceil($0.timeIntervalSince(context.date))) } ?? 0
            Group {
                if remaining > 0 {
                    Text("Too many tries. Wait \(remaining) s.")
                        .foregroundStyle(Theme.mute)
                } else if store.failedAttempts > 0 {
                    Text("Wrong PIN")
                        .foregroundStyle(Theme.mute)
                } else {
                    Text("Ask the sound lead if you don't know it")
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .font(.system(size: 14, weight: .medium))
            .onChange(of: remaining > 0) { _, locked in
                if !locked { entry = "" }
            }
        }
        .frame(height: 20)
    }

    private func submit(_ pin: String) {
        if store.isLockedOut() {
            entry = ""
        } else if store.verifyPIN(pin) {
            store.resetAttempts()
            dismiss()
            onSuccess()
        } else {
            store.registerFailure()
            shakes += 1
            entry = ""
        }
    }
}
