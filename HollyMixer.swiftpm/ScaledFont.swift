import SwiftUI

/// A system font that follows the user's Dynamic Type setting. Used on the pages that are mostly text (Settings,
/// Connect, Backup, Help…); the faders and strips keep fixed sizes so they never reflow in the middle of a service.
private struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight

    init(size: CGFloat, weight: Font.Weight) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight))
    }
}

extension View {
    func scaledFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View {
        modifier(ScaledFont(size: size, weight: weight))
    }

    /// Text-heavy pages grow with Dynamic Type up to a point that still fits their fixed-height controls.
    func textPageTypeSize() -> some View {
        dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}
