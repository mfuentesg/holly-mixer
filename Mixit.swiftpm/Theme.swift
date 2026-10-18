import SwiftUI

/// Shared colours for the dark "graphite console" look.
enum Theme {
    static let background = LinearGradient(
        colors: [Color(red: 0.07, green: 0.075, blue: 0.085), Color(red: 0.025, green: 0.028, blue: 0.035)],
        startPoint: .top,
        endPoint: .bottom
    )
    static let bar = Color(red: 0.085, green: 0.09, blue: 0.1)
    static let card = Color(red: 0.115, green: 0.12, blue: 0.13)
    static let cardBorder = Color.white.opacity(0.07)
    static let track = Color(white: 0.17)
    static let control = Color.white.opacity(0.07)

    static let meterGreen = Color(red: 0.25, green: 0.85, blue: 0.45)
    static let meterAmber = Color(red: 1.0, green: 0.76, blue: 0.2)
    static let meterRed = Color(red: 1.0, green: 0.3, blue: 0.28)
    static let mute = Color(red: 0.93, green: 0.24, blue: 0.24)
}
