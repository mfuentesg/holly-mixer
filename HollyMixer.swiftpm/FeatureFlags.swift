import Foundation

/// User setting: offer the effects (FX 1-4) as mixes in the mix selector. Off by default, because the effects are
/// rarely touched live; each channel's Sends tab still has its FX sends.
enum MixSelectorSettings {
    static let showEffectsKey = "showEffectsInMixSelector"
}

/// Features that exist in the code but are switched off in the current version.
/// Flip a flag to bring a feature back; nothing else needs to change.
enum FeatureFlags {
    /// Mixer snapshots (load/save the mixer's 64 memories). Off until the commands are verified on a real mixer.
    static let snapshots = false

    /// Service Mode: the locked volunteer faders, its layout editor and the PIN that guards leaving it.
    /// Off for the first version. The musician option "With PIN" depends on it and is hidden too.
    static let serviceMode = false
}
