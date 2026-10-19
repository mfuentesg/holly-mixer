import SwiftUI

/// Asks for the 4-digit PIN that the sound lead set on the pairing page before a musician's iPhone leaves
/// musician mode. Three wrong tries lock entry for 30 seconds.
@MainActor
struct MusicianExitPINSheet: View {
    @Environment(\.dismiss) private var dismiss
    let expectedHash: String
    let onSuccess: () -> Void

    @State private var entry = ""
    @State private var shakes = 0
    @State private var failures = 0
    @State private var lockedUntil: Date?

    var body: some View {
        VStack(spacing: 26) {
            Image(systemName: "lock.fill")
                .scaledFont(26, .semibold)
                .foregroundStyle(Theme.accentText)
            Text(L("Enter PIN to exit"))
                .scaledFont(22, .bold)
                .foregroundStyle(Theme.textPrimary)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = lockedUntil.map { Int(ceil($0.timeIntervalSince(context.date))) } ?? 0
                Group {
                    if remaining > 0 {
                        Text(L("Too many tries. Wait \(remaining) s.")).foregroundStyle(Theme.mute)
                    } else if failures > 0 {
                        Text(L("Wrong PIN")).foregroundStyle(Theme.mute)
                    } else {
                        Text(L("Ask the sound lead if you don't know it")).foregroundStyle(Theme.textTertiary)
                    }
                }
                .scaledFont(14, .medium)
            }
            .frame(height: 20)
            ServicePINPad(entry: $entry, length: 4, isDisabled: isLocked, shakes: shakes)
            Button(L("Cancel")) { dismiss() }
                .scaledFont(16, .semibold)
                .foregroundStyle(Theme.textSecondary)
                .frame(minHeight: 44)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .onChange(of: entry) { _, value in
            if value.count == 4 { submit(value) }
        }
    }

    private var isLocked: Bool { lockedUntil.map { $0 > Date() } ?? false }

    private func submit(_ pin: String) {
        if isLocked {
            entry = ""
        } else if MonitorPairing.hash(ofPIN: pin) == expectedHash {
            dismiss()
            onSuccess()
        } else {
            failures += 1
            shakes += 1
            entry = ""
            if failures % 3 == 0 { lockedUntil = Date().addingTimeInterval(30) }
        }
    }
}
