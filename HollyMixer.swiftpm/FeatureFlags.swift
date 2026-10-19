import Foundation

/// Features that exist in the code but are switched off in the current version.
/// Flip a flag to bring a feature back; nothing else needs to change.
enum FeatureFlags {
    /// Service Mode: the locked volunteer faders, its layout editor and the PIN that guards leaving it.
    /// Off for the first version. The musician option "With PIN" depends on it and is hidden too.
    static let serviceMode = false
}
