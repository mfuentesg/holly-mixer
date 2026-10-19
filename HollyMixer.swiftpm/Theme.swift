import SwiftUI

/// Tokens for the "graphite console" design system (see the Holly Mixer design canvas).
enum Theme {
    // Surfaces
    static let background = Color(hex: 0x0B0C0F)
    static let surface = Color(hex: 0x121318)
    static let strip = Color(hex: 0x16181C)
    static let card = Color(hex: 0x1C1E21)
    static let control = Color(hex: 0x22252A)
    static let controlSelected = Color(hex: 0x2C2F35)
    static let well = Color(hex: 0x07080A)
    static let border = Color.white.opacity(0.07)
    static let borderStrong = Color.white.opacity(0.1)

    // Text
    static let textPrimary = Color(hex: 0xF2F3F5)
    static let textBright = Color(hex: 0xE6E8EC)
    static let textControl = Color(hex: 0xC9CCD2)
    static let textSecondary = Color(hex: 0xA4A8B0)
    static let textTertiary = Color(hex: 0x8A8F99)
    static let textMuted = Color(hex: 0x6E737D)
    static let textDim = Color(hex: 0x5A5F69)

    // Accent and status
    static let accent = Color(hex: 0xFF8A1F)
    static let accentText = Color(hex: 0xFFB070)
    static let onAccent = Color(hex: 0x1A0D00)
    static let meterGreen = Color(hex: 0x40D973)
    static let greenText = Color(hex: 0x7BE6A0)
    static let meterAmber = Color(hex: 0xFFC233)
    static let amberText = Color(hex: 0xFFD066)
    static let meterRed = Color(hex: 0xFF4D47)
    static let mute = Color(hex: 0xED3D3D)
    static let muteBorder = Color(hex: 0xFF6B66)
    static let solo = Color(hex: 0xFFC233)
    static let onSolo = Color(hex: 0x1A1405)
    static let demo = Color(hex: 0x9B6BFF)
    static let demoText = Color(hex: 0xD3BEFF)

    /// The 8 X AIR scribble-strip colours and the text colour to use on each.
    static let channelColors: [Color] = [
        Color(hex: 0x737373), Color(hex: 0xF55757), Color(hex: 0x4DD175), Color(hex: 0xFACC42),
        Color(hex: 0x528FFA), Color(hex: 0xDB6BE0), Color(hex: 0x4DC7EB), Color(hex: 0xEBEBEB),
    ]
    static let onChannelColors: [Color] = [
        .white, Color(hex: 0x1A0505), Color(hex: 0x04140A), Color(hex: 0x1A1405),
        Color(hex: 0x06142E), Color(hex: 0x1A061A), Color(hex: 0x041419), Color(hex: 0x0B0C0F),
    ]

    /// Every number (dB, Hz, ms) uses monospaced digits.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Channel names use the rounded face.
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Small all-caps section label: 11 pt bold, +0.8 tracking.
    static let sectionLabel = Font.system(size: 11, weight: .bold)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension View {
    /// The 11 pt uppercase section label style.
    func sectionLabelStyle(_ color: Color = Theme.textTertiary) -> some View {
        font(Theme.sectionLabel).tracking(0.8).foregroundStyle(color)
    }
}
